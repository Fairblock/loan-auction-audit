// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./CollateralManager.sol";
import "./AuctionEngine.sol";
import "./interface/IOracle.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TokenScale} from "./lib/TokenScale.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

using TokenScale for uint256;
using Math for uint256;

/*
 * @title BidManager
 * @dev This contract manages bids for an auction, allowing users to submit and manage their bids.
 */
contract BidManager is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct EncryptedBid {
        uint256 quantity;
        bytes encryptedRate;
        address submitter;
        address[] collateralTokens;
    }

    mapping(uint256 => EncryptedBid) public bids;
    mapping(address => uint256) public bidSubmitted;
    mapping(address => bool) public collateralLocked;
    uint256 private _bidIndex;

    CollateralManager public collatMgr;
    AuctionEngine public auctionEngine;

    uint256 public maxBidAmount;
    uint256 public minimumBidAmount;
    address public token;
    uint8 public tokenDecimals;
    uint256 public maxNumBids;
    uint256 private _bidCount;
    uint256 public constant MAX_COLLATERAL_TOKENS_PER_BID = 10;

    event BidCreated(address indexed submitter, uint256 quantity);
    event BidCollateralUnlocked(
        address indexed bidder,
        address collateralToken,
        uint256 amount
    );
    event ExternalCollateralLocked(
        address indexed borrower,
        address indexed token,
        uint256 amount
    );
    event ExternalCollateralUnlocked(
        address indexed borrower,
        address indexed token,
        uint256 amount
    );

    modifier onlyAuctionEngine() {
        require(msg.sender == address(auctionEngine), "Not auction engine");
        _;
    }
    modifier onlyWhenActive() {
        require(!auctionEngine.paused(), "Auction paused");
        _;
    }

    constructor(
        address _collatMgr,
        address _auctionEngine,
        uint256 _maxBidAmount,
        address _token,
        uint256 _minimumBidAmount,
        uint256 _maxNumBids
    ) ReentrancyGuard() Ownable(msg.sender) {
        require(_collatMgr != address(0), "Zero address");
        require(
            _auctionEngine != address(0),
            "Zero address for auction engine"
        );
        require(_minimumBidAmount > 0, "Invalid min bid amount");
        require(_maxBidAmount > _minimumBidAmount, "Invalid max bid amount");
        require(_token != address(0), "Zero address for token");

        collatMgr = CollateralManager(_collatMgr);
        auctionEngine = AuctionEngine(_auctionEngine);
        maxBidAmount = _maxBidAmount;
        token = _token;
        tokenDecimals = IERC20Metadata(_token).decimals();
        maxNumBids = _maxNumBids;
        minimumBidAmount = _minimumBidAmount;
    }

    // This function allows bidders to submit a new bid or update an existing one.
    function submitBid(
        uint256 bidAmount,
        bytes calldata encryptedRate,
        address[] calldata collateralTokens,
        uint256[] calldata collateralAmounts,
        address baseToken
    ) external nonReentrant onlyWhenActive {
        require(baseToken == token, "Invalid token");
        require(
            collateralTokens.length == collateralAmounts.length,
            "Mismatched input lengths"
        );
        require(encryptedRate.length > 0 && encryptedRate.length <= 256, "invalid encryptedRate size");
        require(
            collateralTokens.length > 0 && collateralTokens.length <= MAX_COLLATERAL_TOKENS_PER_BID,
            "Too many collateral tokens"
        );
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            string memory sym = IERC20Metadata(collateralTokens[i]).symbol();
            for (uint256 j = 0; j < i; j++) {
                require(
                    keccak256(bytes(sym)) !=
                        keccak256(
                            bytes(IERC20Metadata(collateralTokens[j]).symbol())
                        ),
                    "Duplicate underlying collateral"
                );
            }
        }

        require(
            auctionEngine.getAuctionPhase() ==
                AuctionEngine.AuctionPhase.Bidding,
            "Auction not accepting bids"
        );
        require(
            bidAmount > 0 && bidAmount <= maxBidAmount,
            "Invalid bid amount"
        );
        require(bidAmount >= minimumBidAmount, "Bid amount below minimum");
        require(!auctionEngine.auctionCancelled(), "Auction cancelled");
        require(
            !_isInInitialShortFall(
                bidAmount,
                collateralTokens,
                collateralAmounts
            ),
            "In initial shortfall"
        );

        uint256 indexMarker = bidSubmitted[msg.sender];
        bool isNew = indexMarker == 0;
        if (isNew) {
            require(_bidCount + 1 <= maxNumBids, "Max bids reached");
            for (uint256 i = 0; i < collateralTokens.length; i++) {
                collatMgr.lock(
                    msg.sender,
                    collateralTokens[i],
                    collateralAmounts[i]
                );
            }
            bids[_bidIndex] = EncryptedBid(
                bidAmount,
                encryptedRate,
                msg.sender,
                collateralTokens
            );
            bidSubmitted[msg.sender] = _bidIndex + 1;
            _bidIndex++;
            _bidCount++;
            collateralLocked[msg.sender] = true;
            emit BidCreated(msg.sender, bidAmount);
        } else {
            for (uint256 i = 0; i < collateralTokens.length; i++) {
                uint256 oldAmt = collatMgr.lockedBalance(
                    msg.sender,
                    collateralTokens[i]
                );
                if (collateralAmounts[i] > oldAmt) {
                    collatMgr.lock(
                        msg.sender,
                        collateralTokens[i],
                        collateralAmounts[i] - oldAmt
                    );
                } else if (oldAmt > collateralAmounts[i]) {
                    collatMgr.unlock(
                        msg.sender,
                        collateralTokens[i],
                        oldAmt - collateralAmounts[i]
                    );
                }
            }

            EncryptedBid storage existing = bids[indexMarker - 1];
            for (uint256 i = 0; i < existing.collateralTokens.length; i++) {
                address tok = existing.collateralTokens[i];
                bool found = false;
                for (uint256 j = 0; j < collateralTokens.length; j++) {
                    if (tok == collateralTokens[j]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uint256 oldAmt = collatMgr.lockedBalance(msg.sender, tok);
                    if (oldAmt > 0) {
                        collatMgr.unlock(msg.sender, tok, oldAmt);
                    }
                }
            }
            bids[indexMarker - 1] = EncryptedBid(
                bidAmount,
                encryptedRate,
                msg.sender,
                collateralTokens
            );
            emit BidCreated(msg.sender, bidAmount);
        }
    }

    // This function allows the user to remove their bid and unlock the collateral.
    function removeBid() external nonReentrant onlyWhenActive {
        require(!auctionEngine.auctionCancelled(), "Auction cancelled");
        uint256 index = bidSubmitted[msg.sender];
        require(index > 0, "No bid submitted");
        require(
            auctionEngine.getAuctionPhase() ==
                AuctionEngine.AuctionPhase.Bidding,
            "Cannot remove bid"
        );
        require(collateralLocked[msg.sender], "No locked collateral");

        EncryptedBid storage bidEntry = bids[index - 1];
        for (uint256 i = 0; i < bidEntry.collateralTokens.length; i++) {
            uint256 lockedAmt = collatMgr.lockedBalance(
                msg.sender,
                bidEntry.collateralTokens[i]
            );
            if (lockedAmt > 0) {
                collatMgr.unlock(
                    msg.sender,
                    bidEntry.collateralTokens[i],
                    lockedAmt
                );
            }
        }
        collateralLocked[msg.sender] = false;

        uint256 lastIndex = _bidIndex - 1;
        uint256 removeIndex = index - 1;
        if (removeIndex != lastIndex) {
            EncryptedBid storage lastBid = bids[lastIndex];
            bids[removeIndex] = lastBid;
            bidSubmitted[lastBid.submitter] = removeIndex + 1;
        }
        delete bids[lastIndex];
        unchecked {
            --_bidIndex;
        }
        _bidCount--;
        bidSubmitted[msg.sender] = 0;
    }

    // This function allows the auction engine to unlock the collateral for a specific borrower.
    function unlockCollateral(
        address borrower
    ) external onlyAuctionEngine nonReentrant onlyWhenActive {
        require(collateralLocked[borrower], "No locked collateral");
        uint256 index = bidSubmitted[borrower];
        EncryptedBid memory bid = bids[index - 1];
        for (uint256 i = 0; i < bid.collateralTokens.length; i++) {
            uint256 lockedAmt = collatMgr.lockedBalance(
                borrower,
                bid.collateralTokens[i]
            );
            if (lockedAmt > 0) {
                collatMgr.unlock(borrower, bid.collateralTokens[i], lockedAmt);
                emit BidCollateralUnlocked(
                    borrower,
                    bid.collateralTokens[i],
                    lockedAmt
                );
            }
        }
        collateralLocked[borrower] = false;

        // In-place delete only: keeps _bidIndex stable for decryptBidsBatch / bidsDecrypted.
        delete bids[index - 1];
        _bidCount--;
        bidSubmitted[borrower] = 0;
    }

    // This function checks if the borrower's collateral value is above the maintenance ratio.
    function isAboveMaintenance(
        address bidder,
        uint256 assignedAmount,
        UD60x18 clearingRate
    ) public view returns (bool) {
        if (assignedAmount == 0) return true;

        uint256 owedWad = assignedAmount.to18(tokenDecimals).mulDiv(
            1e18 + clearingRate.unwrap(),
            1e18
        );
        uint256 dueUSD = collatMgr.oracle().priceOfTokens(token, owedWad);

        uint256 index = bidSubmitted[bidder];
        if (index == 0) return false;

        address[] memory tokens = bids[index - 1].collateralTokens;
        uint256 totalHaircutUSD;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = collatMgr.collateralBalanceOf(bidder, tokens[i]);
            if (amount == 0) continue;

            uint8 decI = IERC20Metadata(tokens[i]).decimals();
            uint256 wadAmt = amount.to18(decI);
            uint256 rawUSD = collatMgr.oracle().priceOfTokens(
                tokens[i],
                wadAmt
            );

            uint256 ratio = collatMgr.maintenanceRatios(tokens[i]);
            totalHaircutUSD += rawUSD.mulDiv(1, ratio);
        }
        return totalHaircutUSD >= dueUSD;
    }

    // View all bids
    function getBids() external view returns (EncryptedBid[] memory) {
        EncryptedBid[] memory activeBids = new EncryptedBid[](_bidIndex);
        for (uint256 i = 0; i < _bidIndex; i++) {
            activeBids[i] = bids[i];
        }
        return activeBids;
    }

    // This function checks if the borrower is in a shortfall position.
    function isInShortFall(
        address borrower,
        uint256 owedRaw
    ) public view returns (bool) {
        require(bidSubmitted[borrower] > 0, "No bid submitted");

        uint256 owedWad = owedRaw.to18(tokenDecimals);
        uint256 repurchaseUsdValue = collatMgr.oracle().priceOfTokens(
            token,
            owedWad
        );

        uint256 totalHaircut;
        address[] memory collateralTokens = bids[bidSubmitted[borrower] - 1]
            .collateralTokens;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            uint256 balRaw = collatMgr.collateralBalanceOf(
                borrower,
                collateralTokens[i]
            );
            uint8 decI = IERC20Metadata(collateralTokens[i]).decimals();
            uint256 usdValue = collatMgr.oracle().priceOfTokens(
                collateralTokens[i],
                balRaw.to18(decI)
            );

            uint256 ratio = collatMgr.maintenanceRatios(collateralTokens[i]);
            if (ratio == 0) continue;
            totalHaircut += usdValue.mulDiv(1, ratio);
        }
        return totalHaircut < repurchaseUsdValue;
    }

    // Calculate how much collateral and fee to transfer given coveragePaid. (used for liquidation)
    function calculateEquivalentAmount(
        uint256 coveragePaid,
        address collateralToken,
        uint256 liquidatorfeeRate,
        uint256 protocolFeeRate
    ) external view returns (uint256 netCollateral, uint256 feeCollateral) {
        uint256 coveragePaidWad = coveragePaid.to18(tokenDecimals);
        uint256 purchaseUsdValue = collatMgr.oracle().priceOfTokens(
            token,
            coveragePaidWad
        );

        uint8 collDec = IERC20Metadata(collateralToken).decimals();
        uint256 oneCollateralUsd = collatMgr.oracle().priceOfTokens(
            collateralToken,
            1e18
        );
        require(oneCollateralUsd > 0, "Invalid collateral price");

        uint256 collateralWad = Math.mulDiv(
            purchaseUsdValue,
            1e18,
            oneCollateralUsd
        );
        uint256 rawCollateral = collateralWad.from18(collDec);

        uint256 liquidatorBonus = Math.mulDiv(
            rawCollateral,
            liquidatorfeeRate,
            1e18
        );

        uint256 protocolFeeRaw = Math.mulDiv(
            rawCollateral,
            protocolFeeRate,
            1e18
        );

        netCollateral = rawCollateral + liquidatorBonus;
        feeCollateral = protocolFeeRaw;
    }

    // Transfer collateral on liquidation
    function transferCollateral(
        address borrower,
        address liquidator,
        address collateralToken,
        uint256 amount,
        uint256 fee
    ) external onlyAuctionEngine nonReentrant onlyWhenActive {
        require(
            collatMgr.isAcceptedCollateral(collateralToken),
            "Invalid collateral"
        );
        require(amount > 0, "Invalid amount");
        require(fee <= amount, "Fee exceeds collateral amount");

        collatMgr.transfer(borrower, liquidator, collateralToken, amount - fee);
        collatMgr.transfer(
            borrower,
            auctionEngine.owner(),
            collateralToken,
            fee
        );
    }

    // Unlock all bids (in case of cancellation)
    function unlockAllBids()
        external
        onlyAuctionEngine
        nonReentrant
        onlyWhenActive
    {
        while (_bidIndex > 0) {
            uint256 last = _bidIndex - 1;
            EncryptedBid memory bidEntry = bids[last];
            address sub = bidEntry.submitter;
            for (uint256 j = 0; j < bidEntry.collateralTokens.length; j++) {
                uint256 lockedAmt = collatMgr.lockedBalance(
                    sub,
                    bidEntry.collateralTokens[j]
                );
                if (lockedAmt > 0) {
                    collatMgr.unlock(
                        sub,
                        bidEntry.collateralTokens[j],
                        lockedAmt
                    );
                    emit BidCollateralUnlocked(
                        sub,
                        bidEntry.collateralTokens[j],
                        lockedAmt
                    );
                }
            }
            collateralLocked[sub] = false;
            bidSubmitted[sub] = 0;
            delete bids[last];
            unchecked {
                --_bidIndex;
            }
            _bidCount--;
        }
    }

    // Lock extra collateral
    function externalLockCollateral(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant onlyWhenActive {
        require(tokens.length == amounts.length, "len mismatch");
        require(bidSubmitted[msg.sender] > 0, "no active bid");

        for (uint256 i; i < tokens.length; ++i) {
            require(collatMgr.isAcceptedCollateral(tokens[i]), "invalid token");
            require(amounts[i] > 0, "zero amt");
            collatMgr.lock(msg.sender, tokens[i], amounts[i]);
            emit ExternalCollateralLocked(msg.sender, tokens[i], amounts[i]);
        }
    }

    // Unlock excessive collateral
    function externalUnlockCollateral(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external nonReentrant onlyWhenActive {
        require(tokens.length == amounts.length, "len mismatch");
        uint256 bidId = bidSubmitted[msg.sender];
        require(bidId > 0, "no active bid");

        AuctionEngine.AuctionPhase ph = auctionEngine.getAuctionPhase();
        require(
            ph == AuctionEngine.AuctionPhase.LoanWindow ||
                ph == AuctionEngine.AuctionPhase.Repayment,
            "unlock not allowed"
        );
        require(auctionEngine.isFinalized(), "not finalized");

        for (uint256 i; i < tokens.length; ++i) {
            require(amounts[i] > 0, "zero amt");
            require(
                collatMgr.lockedBalance(msg.sender, tokens[i]) >= amounts[i],
                "exceeds locked"
            );
        }

        address[] memory all = bids[bidId - 1].collateralTokens;
        uint256 postHaircutUSD;
        for (uint256 i; i < all.length; ++i) {
            uint256 balRaw = collatMgr.collateralBalanceOf(msg.sender, all[i]);
            for (uint256 j; j < tokens.length; ++j) {
                if (all[i] == tokens[j]) {
                    balRaw -= amounts[j];
                    break;
                }
            }
            if (balRaw == 0) continue;

            uint8 decI = IERC20Metadata(all[i]).decimals();
            uint256 wadAmt = balRaw.to18(decI);
            uint256 rawUSD = collatMgr.oracle().priceOfTokens(all[i], wadAmt);
            uint256 ratio = collatMgr.maintenanceRatios(all[i]);
            if (ratio == 0) continue;
            postHaircutUSD += rawUSD.mulDiv(1, ratio);
        }

        uint256 owedRaw = auctionEngine.repayments(msg.sender);
        if (owedRaw > 0) {
            uint256 owedWad = owedRaw.to18(tokenDecimals);
            uint256 owedUsd = collatMgr.oracle().priceOfTokens(token, owedWad);
            require(postHaircutUSD >= owedUsd, "would breach maintenance");
        }

        for (uint256 i; i < tokens.length; ++i) {
            collatMgr.unlock(msg.sender, tokens[i], amounts[i]);
            emit ExternalCollateralUnlocked(msg.sender, tokens[i], amounts[i]);
        }
    }

    // Initial shortfall check
    function _isInInitialShortFall(
        uint256 bidAmount,
        address[] calldata collateralTokens,
        uint256[] calldata collateralAmounts
    ) internal view returns (bool) {
        uint256 bidWad = bidAmount.to18(tokenDecimals);
        uint256 bidUSD = collatMgr.oracle().priceOfTokens(token, bidWad);
        require(bidUSD > 0, "Invalid bid price");

        uint256 haircutValue;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            require(
                collatMgr.isAcceptedCollateral(collateralTokens[i]),
                "Invalid collateral"
            );
        }
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralAmounts[i] == 0) continue;
            uint256 ratio = collatMgr.initialCollateralRatios(
                collateralTokens[i]
            );
            require(ratio > 0, "Ratio is zero");
            uint8 decI = IERC20Metadata(collateralTokens[i]).decimals();
            uint256 wadColl = collateralAmounts[i].to18(decI);
            uint256 rawCollateralUSD = collatMgr.oracle().priceOfTokens(
                collateralTokens[i],
                wadColl
            );
            require(rawCollateralUSD > 0, "Invalid collateral price");
            uint256 adjusted = rawCollateralUSD.mulDiv(1, ratio);
            haircutValue += adjusted;
        }
        return haircutValue < bidUSD;
    }
}
