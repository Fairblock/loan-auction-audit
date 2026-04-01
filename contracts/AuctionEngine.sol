// SPDX-License-Identifier
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./OfferManager.sol";
import "./LendingVault.sol";
import "./interface/IDecrypter.sol";
import "./BidManager.sol";
import "./AuctionToken.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {TokenScale} from "./lib/TokenScale.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
using TokenScale for uint256;
using Math for uint256;

/*
 * @title AuctionEngine
 * @dev This contract manages the auction process including revealing bids and offers, finalizing, assigning the bids and offers, and repayments.
 */
contract AuctionEngine is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    struct DecodedBid {
        address bidder;
        uint256 quantity;
        UD60x18 rate;
    }
    struct DecodedOffer {
        address offerer;
        uint256 quantity;
        UD60x18 rate;
    }

    OfferManager public offerManager;
    IDecrypter public decrypter;
    string public auctionID;
    AuctionToken public auctionToken;
    BidManager public bidManager;

    UD60x18 public auctionClearingRate;
    uint256 public endTimestamp;
    bool public isFinalized;
    bool public auctionCancelled;
    uint256 public auctionVolume;
    uint256 public auctionTokenAmount;
    uint256 public biddingStart;
    uint256 public biddingEnd;
    uint256 public revealEnd;
    uint256 public repaymentDue;
    uint256 public totalRepayed;
    bool public paused;
    bool public allBidsDecrypted;
    bool public allOffersDecrypted;

    UD60x18 public fraction;
    uint256 public fee;
    uint256 public liquidationFee;
    uint256 public protocolLiquidationFee;
    uint256 public maxBids = 100;
    uint256 public maxOffers = 100;

    UD60x18 public constant maxAllowedRate = UD60x18.wrap(20_000e18);

    DecodedBid[] public bidsRevealed;
    DecodedOffer[] public offersRevealed;
    uint256 public bidsDecrypted;
    uint256 public offersDecrypted;

    mapping(address => uint256) public finalBidAllocation;
    mapping(address => uint256) public finalOfferAllocation;
    mapping(address => uint256) public repayments;
    uint256 public repaymentTotal;
    IERC20 public immutable repaymentToken;
    uint8 public immutable repaymentDecimals;

    event AuctionFinalized(uint256 clearingRate, uint256 clearedVolume);
    event AuctionCancelled(string reason);
    event AuctionPaused();
    event AuctionUnpaused();

    modifier whenNotPaused() {
        require(!paused, "Auction is paused");
        _;
    }
    modifier onlyAuctionToken() {
        require(msg.sender == address(auctionToken), "Not auction token");
        _;
    }

    constructor(
        address _decrypter,
        uint256 _biddingDuration,
        uint256 _revealDuration,
        uint256 _loanDuration,
        string memory _id,
        address _token,
        uint256 _fee,
        uint256 _liquidationFee,
        uint256 _protocolLiquidationfee,
        address _auctionToken,
        uint256 _auctionTokenAmount
    ) Ownable(msg.sender) {
        require(_decrypter != address(0), "Zero address");
        require(_token != address(0), "Zero address");
        decrypter = IDecrypter(_decrypter);
        biddingStart = block.timestamp;
        biddingEnd = biddingStart + _biddingDuration;
        revealEnd = biddingEnd + _revealDuration;
        repaymentDue = revealEnd + _loanDuration;

        fraction = ud((_loanDuration * 1e18) / 31_104_000);
        auctionToken = AuctionToken(_auctionToken);
        endTimestamp = revealEnd;
        auctionID = _id;
        auctionTokenAmount = _auctionTokenAmount;
        fee = _fee;
        liquidationFee = _liquidationFee;
        protocolLiquidationFee = _protocolLiquidationfee;

        repaymentToken = IERC20(_token);
        repaymentDecimals = IERC20Metadata(_token).decimals();
    }

    // Set bid and offer managers
    function setManagers(
        address _bidManager,
        address _offerManager
    ) external onlyOwner {
        require(
            _bidManager != address(0) && _offerManager != address(0),
            "Zero address"
        );
        BidManager bm = BidManager(_bidManager);
        require(
            bm.token() == address(repaymentToken) &&
                bm.tokenDecimals() == repaymentDecimals,
            "Manager token mismatch"
        );
        LendingVault vault = OfferManager(_offerManager).lendingVault();
        require(
            vault.token() == address(repaymentToken) &&
                vault.tokenDecimals() == repaymentDecimals,
            "Vault token mismatch"
        );
        bidManager = bm;
        offerManager = OfferManager(_offerManager);
    }

    function pauseAuction() external onlyOwner {
        paused = true;
        emit AuctionPaused();
    }

    function unpauseAuction() external onlyOwner {
        paused = false;
        emit AuctionUnpaused();
    }

    // Decrypt bids. Batch size should be chosen according to the decryption gas consumption. On Arbitrum, the maximum batch size is 3.
    function decryptBidsBatch(
        uint256 batchSize,
        uint8[] calldata decryptionKey
    ) external onlyOwner whenNotPaused {
        require(!allBidsDecrypted, "All bids decrypted");
        BidManager.EncryptedBid[] memory encBids = bidManager.getBids();
        uint256 n = encBids.length;
        if (n == 0) {
            allBidsDecrypted = true;
            return;
        }
        uint256 processed;
        for (uint256 i = bidsDecrypted; i < n && processed < batchSize; ++i) {
            if (encBids[i].submitter == address(0)) {
                bidsDecrypted++;
                processed++;
                continue;
            }
            uint8[] memory out; try decrypter.decrypt(_toUint8Array(encBids[i].encryptedRate), decryptionKey) returns (uint8[] memory r) { out = r; } catch { bidsDecrypted++; processed++; bidManager.unlockCollateral(encBids[i].submitter); continue; }
            bool valid = true;
            for (uint256 k; k < out.length; ++k) {
                if (out[k] < 48 || out[k] > 57) {
                    valid = false;
                    break;
                }
            }
            if (!valid) {
                bidsDecrypted++;
                processed++;
                bidManager.unlockCollateral(encBids[i].submitter);
                continue;
            }
            if (out.length > 77) { bidsDecrypted++; processed++; bidManager.unlockCollateral(encBids[i].submitter); continue; }
            uint256 rawRate = _uint8ArrayToUint256(out);
            if (rawRate > 20000) { bidsDecrypted++; processed++; bidManager.unlockCollateral(encBids[i].submitter); continue; }
            UD60x18 rate = ud(rawRate * 1e18);
            if (rate.gt(maxAllowedRate)) {
                bidsDecrypted++;
                processed++;
                continue;
            }
            bidsRevealed.push(
                DecodedBid(encBids[i].submitter, encBids[i].quantity, rate)
            );
            bidsDecrypted++;
            processed++;
        }
        if (bidsDecrypted == n) allBidsDecrypted = true;
    }

    // Decrypt offer. Batch size should be chosen according to the decryption gas consumption. On Arbitrum, the maximum batch size is 3.
    function decryptOffersBatch(
        uint256 batchSize,
        uint8[] calldata decryptionKey
    ) external onlyOwner whenNotPaused {
        require(!allOffersDecrypted, "All offers decrypted");
        OfferManager.EncryptedOffer[] memory encOffers = offerManager
            .getOffers();
        uint256 n = encOffers.length;
        if (n == 0) {
            allOffersDecrypted = true;
            return;
        }
        uint256 processed;
        for (uint256 i = offersDecrypted; i < n && processed < batchSize; ++i) {
            if (encOffers[i].submitter == address(0)) {
                offersDecrypted++;
                continue;
            }
            uint8[] memory out; try decrypter.decrypt(_toUint8Array(encOffers[i].encryptedRate), decryptionKey) returns (uint8[] memory r) { out = r; } catch { offersDecrypted++; processed++; offerManager.unlockFunds(encOffers[i].submitter, encOffers[i].quantity); continue; }
            bool valid = true;
            for (uint256 k; k < out.length; ++k) {
                if (out[k] < 48 || out[k] > 57) {
                    valid = false;
                    break;
                }
            }
            if (!valid) {
                offersDecrypted++;
                processed++;
                offerManager.unlockFunds(
                    encOffers[i].submitter,
                    encOffers[i].quantity
                );
                continue;
            }
            if (out.length > 77) { offersDecrypted++; processed++; offerManager.unlockFunds(encOffers[i].submitter, encOffers[i].quantity); continue; }
            uint256 rawRate = _uint8ArrayToUint256(out);
            if (rawRate > 20000) { offersDecrypted++; processed++; offerManager.unlockFunds(encOffers[i].submitter, encOffers[i].quantity); continue; }
            UD60x18 rate = ud(rawRate * 1e18);
            if (rate.gt(maxAllowedRate)) {
                offersDecrypted++;
                processed++;
                continue;
            }
            offersRevealed.push(
                DecodedOffer(
                    encOffers[i].submitter,
                    encOffers[i].quantity,
                    rate
                )
            );
            offersDecrypted++;
            processed++;
        }
        if (offersDecrypted == n) allOffersDecrypted = true;
    }

    // Finalize auction, calculate the clearing price, and assign bids and offers
    function finalizeAuction() external onlyOwner whenNotPaused nonReentrant {
        require(!isFinalized, "Already finalized");
        require(!auctionCancelled, "Auction cancelled");
        require(allBidsDecrypted, "Not all bids decrypted");
        require(allOffersDecrypted, "Not all offers decrypted");
        require(bidsRevealed.length <= maxBids, "Exceeded max bids allowed");
        require(
            offersRevealed.length <= maxOffers,
            "Exceeded max offers allowed"
        );
        // require(
        //     getAuctionPhase() == AuctionPhase.Reveal,
        //     "Auction not in reveal phase"
        // );
        if (bidsRevealed.length == 0 || offersRevealed.length == 0) {
            auctionClearingRate = ud(0);
            auctionVolume = 0;
            _assignBids(ud(0), 0);
            _assignOffers(ud(0), 0);
            isFinalized = true;
            emit AuctionFinalized(0, 0);
            return;
        }
        _sortBids();
        _sortOffers();

        (UD60x18 clrPrice, uint256 clearedVolume) = _calculateClearingPrice();
        auctionClearingRate = clrPrice;
        auctionVolume = clearedVolume;

        _assignBids(clrPrice, clearedVolume);
        _assignOffers(clrPrice, clearedVolume);

        isFinalized = true;
        emit AuctionFinalized(UD60x18.unwrap(clrPrice), clearedVolume);
    }

    // Cancel the auction and return the locked funds and collaterals
    function cancelAuction(
        string calldata reason
    ) external onlyOwner nonReentrant {
        require(!isFinalized, "Already finalized");
        require(!auctionCancelled, "Already cancelled");
        require(block.timestamp < biddingEnd, "Already finished");
        auctionCancelled = true;
        offerManager.unlockAllOffers();
        bidManager.unlockAllBids();
        emit AuctionCancelled(reason);
    }

    // Repay by borrower during the repayment period
    function repay(uint256 amountRaw) external nonReentrant whenNotPaused {
        uint256 owed = repayments[msg.sender];
        require(owed > 0 && amountRaw <= owed, "invalid amount");
        require(
            getAuctionPhase() == AuctionPhase.Repayment ||
                getAuctionPhase() == AuctionPhase.LoanWindow,
            "Not in correct phase"
        );
        repayments[msg.sender] = owed - amountRaw;
        repaymentTotal -= amountRaw;
        totalRepayed += amountRaw;
        repaymentToken.safeTransferFrom(
            msg.sender,
            address(offerManager.lendingVault()),
            amountRaw
        );
        if (repayments[msg.sender] == 0)
            bidManager.unlockCollateral(msg.sender);
    }

    // Repay function with auction token instead of purchase token
    function repayWithAuctionToken(
        uint256 auctionAmount
    ) external nonReentrant whenNotPaused {
        uint256 owed = repayments[msg.sender];
        require(owed > 0, "Nothing owed");
        require(
            getAuctionPhase() == AuctionPhase.Repayment ||
                getAuctionPhase() == AuctionPhase.LoanWindow,
            "Not in correct phase"
        );

        uint256 repayRaw = auctionAmount.mulDiv(auctionTokenAmount, 1e18);
        require(repayRaw <= owed, "Repay exceeds debt");

        auctionToken.burn(msg.sender, auctionAmount);

        repayments[msg.sender] -= repayRaw;
        repaymentTotal -= repayRaw;
        totalRepayed += repayRaw;

        if (repayments[msg.sender] == 0) {
            bidManager.unlockCollateral(msg.sender);
        }
    }

    // Liquidation of borrower's collateral in case of short fall
    function batchEarlyLiquidation(
        address participant,
        address[] calldata collateralTokens,
        uint256[] calldata coverageAmounts
    ) external nonReentrant whenNotPaused {
        require(
            block.timestamp < repaymentDue + 172_800,
            "Use batchLateLiquidation"
        );
        require(
            collateralTokens.length == coverageAmounts.length,
            "Array mismatch"
        );
        require(msg.sender != participant, "Self liquidation not allowed!");

        uint256 owed = repayments[participant];
        require(owed > 0, "No debt");
        require(
            bidManager.isInShortFall(participant, owed),
            "Not undercollateralized"
        );

        uint256 totalCoverage;
        for (uint256 i; i < coverageAmounts.length; ++i)
            totalCoverage += coverageAmounts[i];
        require(totalCoverage <= owed, "Exceeds debt");

        repayments[participant] = owed - totalCoverage;
        repaymentTotal -= totalCoverage;
        totalRepayed += totalCoverage;
        repaymentToken.safeTransferFrom(
            msg.sender,
            address(offerManager.lendingVault()),
            totalCoverage
        );
        for (uint256 i; i < coverageAmounts.length; ++i) {
            (uint256 seized, uint256 seizedFee) = bidManager
                .calculateEquivalentAmount(
                    coverageAmounts[i],
                    collateralTokens[i],
                    liquidationFee,
                    protocolLiquidationFee
                );
            bidManager.transferCollateral(
                participant,
                msg.sender,
                collateralTokens[i],
                seized,
                seizedFee
            );
        }
    }

    // Liquidation of borrower's collaterals in case of missed repayment
    function batchLateLiquidation(
        address participant,
        address[] calldata collateralTokens,
        uint256[] calldata coverageAmounts
    ) external nonReentrant whenNotPaused {
        require(
            block.timestamp >= repaymentDue + 172_800,
            "Use batchEarlyLiquidation"
        );
        require(
            collateralTokens.length == coverageAmounts.length,
            "Array mismatch"
        );
        require(msg.sender != participant, "Self liquidation not allowed!");
        uint256 owed = repayments[participant];
        require(owed > 0, "No debt");

        uint256 totalCoverage;
        for (uint256 i; i < coverageAmounts.length; ++i)
            totalCoverage += coverageAmounts[i];
        require(totalCoverage <= owed, "Exceeds debt");

        repayments[participant] = owed - totalCoverage;
        repaymentTotal -= totalCoverage;
        totalRepayed += totalCoverage;
        repaymentToken.safeTransferFrom(
            msg.sender,
            address(offerManager.lendingVault()),
            totalCoverage
        );

        for (uint256 i; i < coverageAmounts.length; ++i) {
            (uint256 seized, uint256 seizedFee) = bidManager
                .calculateEquivalentAmount(
                    coverageAmounts[i],
                    collateralTokens[i],
                    liquidationFee,
                    protocolLiquidationFee
                );
            bidManager.transferCollateral(
                participant,
                msg.sender,
                collateralTokens[i],
                seized,
                seizedFee
            );
        }
    }

    // Redeem auction token to receive purchase token
    function auctionTokenRedeem(
        address to,
        uint256 auctionAmount
    ) external onlyAuctionToken whenNotPaused {
        uint256 payoutRaw = auctionAmount.mulDiv(auctionTokenAmount, 1e18);
        offerManager.transferFunds(to, payoutRaw);
    }

    function bidsRevealedLength() external view returns (uint256) {
        return bidsRevealed.length;
    }

    function offersRevealedLength() external view returns (uint256) {
        return offersRevealed.length;
    }

    enum AuctionPhase {
        Bidding,
        Reveal,
        Repayment,
        Redemption,
        LoanWindow
    }

    function getAuctionPhase() public view returns (AuctionPhase) {
        if (block.timestamp >= biddingStart && block.timestamp < biddingEnd)
            return AuctionPhase.Bidding;
        if (block.timestamp >= biddingEnd && block.timestamp < revealEnd)
            return AuctionPhase.Reveal;
        if (block.timestamp >= revealEnd && block.timestamp <= repaymentDue)
            return AuctionPhase.LoanWindow;
        if (
            block.timestamp >= repaymentDue &&
            block.timestamp < repaymentDue + 172_800
        ) return AuctionPhase.Repayment;
        if (block.timestamp >= repaymentDue + 172_800)
            return AuctionPhase.Redemption;
        revert("Auction phase undefined");
    }

    // Internal sorting of bids from highest to lowest
    function _sortBids() internal {
        uint256 n = bidsRevealed.length;
        DecodedBid[] memory arr = new DecodedBid[](n);
        for (uint256 i; i < n; ++i) {
            arr[i] = bidsRevealed[i];
        }
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n - 1 - i; ++j) {
                if (arr[j].rate.lt(arr[j + 1].rate)) {
                    DecodedBid memory tmp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = tmp;
                }
            }
        }
        for (uint256 k; k < n; ++k) {
            bidsRevealed[k] = arr[k];
        }
    }

    // Internal sorting of offers from lowest to highest
    function _sortOffers() internal {
        uint256 n = offersRevealed.length;
        DecodedOffer[] memory arr = new DecodedOffer[](n);
        for (uint256 i; i < n; ++i) {
            arr[i] = offersRevealed[i];
        }
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n - 1 - i; ++j) {
                if (arr[j].rate.gt(arr[j + 1].rate)) {
                    DecodedOffer memory tmp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = tmp;
                }
            }
        }
        for (uint256 k; k < n; ++k) {
            offersRevealed[k] = arr[k];
        }
    }

    // Calculating the clearing price
    function _calculateClearingPrice()
        internal
        view
        returns (UD60x18, uint256)
    {
        if (bidsRevealed.length == 0 || offersRevealed.length == 0) {
            return (ud(0), 0);
        }

        uint256 accumSupply;
        uint256 bestVolume;
        UD60x18 pivotOfferRate;
        for (uint256 i; i < offersRevealed.length; ) {
            UD60x18 currentRate = offersRevealed[i].rate;
            uint256 sumOffers;
            while (
                i < offersRevealed.length &&
                offersRevealed[i].rate.eq(currentRate)
            ) {
                sumOffers += offersRevealed[i].quantity;
                ++i;
            }
            accumSupply += sumOffers;

            uint256 demand;
            for (uint256 j; j < bidsRevealed.length; ++j) {
                if (bidsRevealed[j].rate.gte(currentRate))
                    demand += bidsRevealed[j].quantity;
                else break;
            }
            uint256 volume = accumSupply < demand ? accumSupply : demand;
            if (volume > bestVolume) {
                bestVolume = volume;
                pivotOfferRate = currentRate;
            }
        }

        if (bestVolume == 0) {
            return (ud(0), 0);
        }

        // Price formation: matchedMarginalBidRate comes from the last bid that receives a
        // positive fill when simulating top-down allocation of bestVolume (discrete max volume).
        // Dust bids at or above the pivot but with zero fill cannot set the marginal rate.
        uint256 remainingVolume = bestVolume;
        uint256 actualMarginalBidIndex;
        for (uint256 i; i < bidsRevealed.length && remainingVolume > 0; ++i) {
            uint256 q = bidsRevealed[i].quantity;
            uint256 fillable = q < remainingVolume ? q : remainingVolume;
            if (fillable > 0) {
                actualMarginalBidIndex = i;
                remainingVolume -= fillable;
            }
        }

        UD60x18 matchedMarginalBidRate = bidsRevealed[actualMarginalBidIndex].rate;
        UD60x18 finalRate = (matchedMarginalBidRate + pivotOfferRate) / ud(2e18);

        return (finalRate, bestVolume);
    }

    /// @dev Hamilton (largest-remainder) apportionment: proportional floor shares, then +1 to top
    ///      fractional remainders; ties broken by address (deterministic, order-neutral).
    function _allocateLargestRemainder(
        uint256 rem,
        uint256 i,
        uint256 j,
        uint256 sumQty,
        UD60x18 clearingRate,
        bool forBids
    ) internal {
        uint256 n = j - i;
        uint256[] memory bases = new uint256[](n);
        uint256[] memory fracRems = new uint256[](n);
        uint256 totalBase;

        for (uint256 k = i; k < j; ++k) {
            uint256 idx = k - i;
            uint256 q = forBids
                ? bidsRevealed[k].quantity
                : offersRevealed[k].quantity;
            bases[idx] = Math.mulDiv(rem, q, sumQty);
            fracRems[idx] = mulmod(rem, q, sumQty);
            totalBase += bases[idx];
        }

        uint256 unitsLeft = rem - totalBase;
        for (uint256 u; u < unitsLeft; ++u) {
            uint256 maxFrac;
            address maxAddr;
            uint256 maxIdx;
            for (uint256 idx; idx < n; ++idx) {
                address addr = forBids
                    ? bidsRevealed[i + idx].bidder
                    : offersRevealed[i + idx].offerer;
                if (
                    fracRems[idx] > maxFrac ||
                    (fracRems[idx] == maxFrac &&
                        uint160(addr) > uint160(maxAddr))
                ) {
                    maxFrac = fracRems[idx];
                    maxAddr = addr;
                    maxIdx = idx;
                }
            }
            bases[maxIdx] += 1;
            fracRems[maxIdx] = 0;
        }

        for (uint256 k = i; k < j; ++k) {
            uint256 idx = k - i;
            uint256 alloc = bases[idx];
            if (forBids) {
                finalBidAllocation[bidsRevealed[k].bidder] = alloc;
                _finalizeBidAssignment(
                    bidsRevealed[k].bidder,
                    alloc,
                    clearingRate
                );
            } else {
                uint256 qFull = offersRevealed[k].quantity;
                finalOfferAllocation[offersRevealed[k].offerer] = alloc;
                _finalizeOfferAssignment(
                    offersRevealed[k].offerer,
                    alloc,
                    qFull,
                    clearingRate
                );
            }
        }
    }

    // Assigning offers to bidders
    function _assignBids(UD60x18 clearingRate, uint256 totalCleared) internal {
        uint256 rem = totalCleared;
        uint256 len = bidsRevealed.length;
        for (uint256 i; i < len && rem > 0; ) {
            uint256 j = i + 1;
            while (j < len && bidsRevealed[j].rate.eq(bidsRevealed[i].rate))
                ++j;

            uint256 sumQty;
            for (uint256 k = i; k < j; ++k) sumQty += bidsRevealed[k].quantity;

            if (sumQty <= rem) {
                for (uint256 k = i; k < j; ++k) {
                    uint256 q = bidsRevealed[k].quantity;
                    finalBidAllocation[bidsRevealed[k].bidder] = q;
                    _finalizeBidAssignment(
                        bidsRevealed[k].bidder,
                        q,
                        clearingRate
                    );
                    rem -= q;
                }
            } else {
                _allocateLargestRemainder(rem, i, j, sumQty, clearingRate, true);
                rem = 0;
            }
            i = j;
        }
        for (uint256 m; m < len; ++m) {
            address bidder = bidsRevealed[m].bidder;
            if (finalBidAllocation[bidder] == 0)
                bidManager.unlockCollateral(bidder);
        }
    }

    // Assigning bids to offerers
    function _assignOffers(
        UD60x18 clearingRate,
        uint256 totalCleared
    ) internal {
        uint256 rem = totalCleared;
        uint256 len = offersRevealed.length;
        for (uint256 i; i < len && rem > 0; ) {
            uint256 j = i + 1;
            while (j < len && offersRevealed[j].rate.eq(offersRevealed[i].rate))
                ++j;

            uint256 sumQty;
            for (uint256 k = i; k < j; ++k)
                sumQty += offersRevealed[k].quantity;

            if (sumQty <= rem) {
                for (uint256 k = i; k < j; ++k) {
                    uint256 q = offersRevealed[k].quantity;
                    finalOfferAllocation[offersRevealed[k].offerer] = q;
                    _finalizeOfferAssignment(
                        offersRevealed[k].offerer,
                        q,
                        offersRevealed[k].quantity,
                        clearingRate
                    );
                    rem -= q;
                }
            } else {
                _allocateLargestRemainder(rem, i, j, sumQty, clearingRate, false);
                rem = 0;
            }
            i = j;
        }
        for (uint256 m; m < len; ++m) {
            address off = offersRevealed[m].offerer;
            if (finalOfferAllocation[off] == 0)
                offerManager.unlockFunds(off, offersRevealed[m].quantity);
        }
    }

    function _finalizeBidAssignment(
        address bidder,
        uint256 quantityToken,
        UD60x18 clearingRate
    ) internal {
        if (quantityToken == 0) return;
        UD60x18 scaledFactor = ud(100e18) + fraction.mul(clearingRate);
        UD60x18 repayFixedWad = ud(_to18(quantityToken)).mul(scaledFactor) /
            ud(100e18);

        uint256 repayWad = UD60x18.unwrap(repayFixedWad);
        uint256 repayRaw = repayWad.from18(repaymentDecimals);

        repayments[bidder] += repayRaw;
        repaymentTotal += repayRaw;

        uint256 annualInterestRaw = Math.mulDiv(quantityToken, fee, 1e18);

        uint256 fractionWad = UD60x18.unwrap(fraction);
        uint256 feeRaw = Math.mulDiv(annualInterestRaw, fractionWad, 1e18);

        offerManager.transferFunds(owner(), feeRaw);
        offerManager.transferFunds(bidder, quantityToken - feeRaw);
    }

    function _finalizeOfferAssignment(
        address offerer,
        uint256 quantityToken,
        uint256 offerAmountToken,
        UD60x18 rate
    ) internal {
        UD60x18 scaledFactor = ud(100e18) + fraction.mul(rate);

        UD60x18 repayFixedWad = ud(_to18(quantityToken)).mul(scaledFactor) /
            ud(100e18);

        uint256 repayWad = UD60x18.unwrap(repayFixedWad);
        uint256 repayRaw = repayWad.from18(repaymentDecimals);

        offerManager.unlockFunds(offerer, offerAmountToken - quantityToken);

        uint256 mintRaw = Math.mulDiv(repayRaw, 1e18, auctionTokenAmount);

        auctionToken.mintForOffer(offerer, mintRaw);
    }

    function _to18(uint256 raw) internal view returns (uint256) {
        return raw.to18(repaymentDecimals);
    }

    function _toUint8Array(
        bytes memory data
    ) internal pure returns (uint8[] memory) {
        uint8[] memory arr = new uint8[](data.length);
        for (uint256 i; i < data.length; ++i) arr[i] = uint8(data[i]);
        return arr;
    }

    function _uint8ArrayToUint256(
        uint8[] memory arr
    ) internal pure returns (uint256 result) {
        for (uint256 i; i < arr.length; ++i) {
            require(arr[i] >= 48 && arr[i] <= 57, "Non-numeric");
            result = result * 10 + (arr[i] - 48);
        }
    }
}
