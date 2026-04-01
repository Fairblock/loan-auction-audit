// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LendingVault.sol";
import "./AuctionEngine.sol";
/*
 * @title OfferManager
 * @dev This contract manages offers for an auction, allowing users to submit and manage their offers.
 */
contract OfferManager is Ownable, ReentrancyGuard {
    struct EncryptedOffer {
        address submitter;
        uint256 quantity;
        bytes encryptedRate;
    }

    mapping(uint256 => EncryptedOffer) public offers;
    mapping(address => uint256) public offerSubmitted;
    mapping(address => uint256) public lockedOfferFunds;
    LendingVault public lendingVault;
    AuctionEngine public auctionEngine;
    uint256 public maxOfferAmount;
    uint256 public minimumOfferAmount;
    uint256 private _offerIndex;
    uint256 private _offerCount;
    uint256 public maxNumOffers;

    uint256 public removalCutoffBuffer = 1 hours;
    mapping(address => bool) public whitelistedLenders;
    bool public whitelistEnabled;

    event RemovalCutoffUpdated(uint256 newBuffer);
    event WhitelistStatusChanged(bool enabled);
    event LenderWhitelisted(address indexed lender, bool status);

    event OfferSubmitted(
        address indexed user,
        uint256 qty,
        bytes encryptedRate
    );
    event OfferFundsUnlocked(address indexed user, uint256 amount);

    constructor(
        address _lendingVault,
        address _auctionEngine,
        uint256 _maxOfferAmount,
        uint256 _minimumOfferAmount,
        uint256 _maxNumOffers
    ) Ownable(msg.sender) {
        require(_lendingVault != address(0), "Zero address");
        require(_auctionEngine != address(0), "Zero address");
        require(_maxOfferAmount > 0, "Invalid max offer amount");
        require(_minimumOfferAmount > 0, "Invalid min offer amount");
        require(
            _minimumOfferAmount <= _maxOfferAmount,
            "Min offer amount exceeds max"
        );
        lendingVault = LendingVault(_lendingVault);
        auctionEngine = AuctionEngine(_auctionEngine);
        maxOfferAmount = _maxOfferAmount;
        minimumOfferAmount = _minimumOfferAmount;
        maxNumOffers = _maxNumOffers;
    }

    modifier onlyAuctionEngine() {
        require(msg.sender == address(auctionEngine), "Not auction engine");
        _;
    }
    modifier onlyWhenActive() {
        require(!auctionEngine.paused(), "Auction paused");
        _;
    }

    modifier onlyWhitelistedOrOpen() {
        require(
            !whitelistEnabled || whitelistedLenders[msg.sender],
            "Not whitelisted"
        );
        _;
    }

    function setRemovalCutoffBuffer(uint256 buffer) external onlyOwner {
        require(buffer <= 24 hours, "Buffer too large");
        removalCutoffBuffer = buffer;
        emit RemovalCutoffUpdated(buffer);
    }

    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistStatusChanged(enabled);
    }

    function setWhitelistedLender(address lender, bool status) external onlyOwner {
        whitelistedLenders[lender] = status;
        emit LenderWhitelisted(lender, status);
    }

    function batchWhitelistLenders(
        address[] calldata lenders,
        bool status
    ) external onlyOwner {
        for (uint256 i = 0; i < lenders.length; i++) {
            whitelistedLenders[lenders[i]] = status;
            emit LenderWhitelisted(lenders[i], status);
        }
    }

    // Submit an offer or update an existing one.
    function submitOffer(
        uint256 quantity,
        bytes calldata encryptedRate
    ) external nonReentrant onlyWhenActive onlyWhitelistedOrOpen {
        require(
            auctionEngine.getAuctionPhase() ==
                AuctionEngine.AuctionPhase.Bidding,
            "Auction not accepting bids"
        );
        require(!auctionEngine.auctionCancelled(), "Auction cancelled");
        require(
            quantity > 0 &&
                quantity <= maxOfferAmount &&
                quantity >= minimumOfferAmount,
            "Invalid quantity"
        );

        uint256 oldAmount = lockedOfferFunds[msg.sender];

        if (oldAmount == 0) {
            require(
                _offerCount + 1 <= maxNumOffers,
                "Maximum number of offers reached."
            );
            lendingVault.lockFunds(msg.sender, quantity);
            offers[_offerIndex] = EncryptedOffer(
                msg.sender,
                quantity,
                encryptedRate
            );
            offerSubmitted[msg.sender] = _offerIndex + 1;
            lockedOfferFunds[msg.sender] = quantity;
            _offerIndex++;
            _offerCount++;
            emit OfferSubmitted(msg.sender, quantity, encryptedRate);
            return;
        } else if (oldAmount < quantity) {
            uint256 diff = quantity - oldAmount;
            lendingVault.lockFunds(msg.sender, diff);
        } else if (oldAmount > quantity) {
            uint256 diff = oldAmount - quantity;
            lendingVault.unlockFunds(msg.sender, diff);
        }
        lockedOfferFunds[msg.sender] = quantity;
        offers[offerSubmitted[msg.sender] - 1] = EncryptedOffer(
            msg.sender,
            quantity,
            encryptedRate
        );
        emit OfferSubmitted(msg.sender, quantity, encryptedRate);
    }
    // Unlock funds for a specific offerer. Only called from the auction engine.
    function unlockFunds(
        address offerer,
        uint256 amount
    ) external onlyAuctionEngine nonReentrant onlyWhenActive {
        uint256 amt = lockedOfferFunds[offerer];
        require(amt > 0, "No locked funds");
        require(amount <= amt, "Insufficient locked funds");

        lockedOfferFunds[offerer] = amt - amount;
        lendingVault.unlockFunds(offerer, amount);
        emit OfferFundsUnlocked(offerer, amount);
    }
    // Remove an offer and unlock the funds.
    function removeOffer() external nonReentrant onlyWhenActive {
        require(auctionEngine.auctionCancelled() == false, "Auction cancelled");
        require(offerSubmitted[msg.sender] > 0, "No offer submitted");
        require(
            auctionEngine.getAuctionPhase() ==
                AuctionEngine.AuctionPhase.Bidding,
            "Cannot remove offer"
        );
        uint256 biddingEnd = auctionEngine.biddingEnd();
        require(
            block.timestamp + removalCutoffBuffer < biddingEnd,
            "Removal window closed"
        );
        uint256 amt = lockedOfferFunds[msg.sender];
        require(amt > 0, "No locked funds");

        lockedOfferFunds[msg.sender] = 0;
        lendingVault.unlockFunds(msg.sender, amt);

        uint256 index = offerSubmitted[msg.sender];
        uint256 lastIndex = _offerIndex - 1;
        uint256 removeIndex = index - 1;
        if (removeIndex != lastIndex) {
            EncryptedOffer storage lastOffer = offers[lastIndex];
            offers[removeIndex] = lastOffer;
            offerSubmitted[lastOffer.submitter] = removeIndex + 1;
        }
        delete offers[lastIndex];
        unchecked {
            --_offerIndex;
        }
        _offerCount--;
        offerSubmitted[msg.sender] = 0;
        emit OfferFundsUnlocked(msg.sender, amt);
    }
    // Get all offers
    function getOffers() external view returns (EncryptedOffer[] memory) {
        EncryptedOffer[] memory offersList = new EncryptedOffer[](_offerIndex);
        for (uint256 i = 0; i < _offerIndex; i++) {
            offersList[i] = offers[i];
        }
        return offersList;
    }
    // Transfer funds to a specified address through lending vault. Only called from the auction engine.
    function transferFunds(
        address to,
        uint256 amount
    ) external onlyAuctionEngine nonReentrant onlyWhenActive {
        require(to != address(0), "Zero address");
        lendingVault.transferFunds(to, amount);
    }
    // Unlock all offers and reset the offer index. Only called from the auction engine in case of cancellation.
    function unlockAllOffers()
        external
        onlyAuctionEngine
        nonReentrant
        onlyWhenActive
    {
        while (_offerIndex > 0) {
            uint256 last = _offerIndex - 1;
            EncryptedOffer memory offer = offers[last];
            address sub = offer.submitter;
            uint256 amt = lockedOfferFunds[sub];
            if (amt > 0) {
                lockedOfferFunds[sub] = 0;
                lendingVault.unlockFunds(sub, amt);
                emit OfferFundsUnlocked(sub, amt);
            }
            offerSubmitted[sub] = 0;
            delete offers[last];
            unchecked {
                --_offerIndex;
            }
            _offerCount--;
        }
    }
}
