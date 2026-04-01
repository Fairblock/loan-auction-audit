// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./AuctionEngine.sol";
/* 
 * @title AuctionToken
 * @dev This contract represents the token used in the auction system for lenders to redeem their funds and interests.
 *      It allows minting, burning, and redeeming tokens based on auction phases.
 */
contract AuctionToken is ERC20, Ownable, ReentrancyGuard {
    address public auctionContract;

    modifier onlyAuction() {
        require(msg.sender == auctionContract, "Not authorized");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) ReentrancyGuard() {}

    function setAuctionContract(address _auctionContract) external onlyOwner {
        auctionContract = _auctionContract;
    }

    function mintForOffer(address to, uint256 amountRaw) external onlyAuction {
        _mint(to, amountRaw);
    }

    function redeemToken(uint256 amountRaw) external nonReentrant {
        require(auctionContract != address(0), "Auction not set");
        AuctionEngine auction = AuctionEngine(auctionContract);

        require(
            auction.getAuctionPhase() == AuctionEngine.AuctionPhase.Redemption,
            "Redemption not allowed"
        );

        require(balanceOf(msg.sender) >= amountRaw, "Insufficient balance");

        uint256 supplyRaw = totalSupply();
        uint256 repayedRaw = auction.totalRepayed();
        uint256 atAmount = auction.auctionTokenAmount();
        uint256 repaidInAT = Math.mulDiv(repayedRaw, 1e18, atAmount);

        if (supplyRaw <= repaidInAT) {
            _burn(msg.sender, amountRaw);
            auction.auctionTokenRedeem(msg.sender, amountRaw);
        } else {
            uint256 redeemAT = Math.mulDiv(amountRaw, repaidInAT, supplyRaw);
            _burn(msg.sender, amountRaw);
            auction.auctionTokenRedeem(msg.sender, redeemAT);
        }
    }

    function burn(
        address user,
        uint256 amountRaw
    ) external nonReentrant onlyAuction {
        require(balanceOf(user) >= amountRaw, "Insufficient balance");
        _burn(user, amountRaw);
    }
}
