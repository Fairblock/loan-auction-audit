// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LendingVault
 * @dev This contract manages the locking and unlocking of funds for offerers.
 */
contract LendingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event FundsLocked(address indexed user, uint256 amount);
    event FundsUnlocked(address indexed user, uint256 amount);
    event CreditAccrued(address indexed to, uint256 amount);
    event ManagerUpdated(
        address indexed oldManager,
        address indexed newManager
    );

    address public token;
    address public manager;
    mapping(address => uint256) public locked;
    /// @notice Purchase-token balance credited when direct transfer fails (e.g. blocked recipient).
    mapping(address => uint256) public claimable;
    uint8   public tokenDecimals;

    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0), "Zero address");
        token = _token;
        tokenDecimals = IERC20Metadata(token).decimals();
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Not authorized");
        _;
    }

    // This function locks funds for an offerer.
    // `amountRaw` is in the token's smallest unit.
    function lockFunds(
        address user,
        uint256 amountRaw
    ) external onlyManager nonReentrant {
        locked[user] += amountRaw;
        IERC20(token).safeTransferFrom(user, address(this), amountRaw);

        emit FundsLocked(user, amountRaw);
    }

    // This function unlocks funds for an offerer.
    // `amountRaw` is in the token's smallest unit.
    function unlockFunds(
        address user,
        uint256 amountRaw
    ) external onlyManager nonReentrant {
        require(user != address(0), "Zero address");
        require(locked[user] >= amountRaw, "Not locked");

        locked[user] -= amountRaw;
        _transferOrCredit(user, amountRaw);
        emit FundsUnlocked(user, amountRaw);
    }

    // This function sets the manager address.
    function setManager(address _manager) external onlyOwner nonReentrant {
        require(_manager != address(0), "Zero manager");
        address oldManager = manager;
        manager = _manager;
        emit ManagerUpdated(oldManager, _manager);
    }

    // This function transfers funds to a specified address.
    // `amountRaw` is in the token's smallest unit.
    function transferFunds(
        address to,
        uint256 amountRaw
    ) external onlyManager nonReentrant {
        require(to != address(0), "Zero address");
        _transferOrCredit(to, amountRaw);
    }

    /// @notice Pull tokens previously credited after a failed transfer.
    function claim() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        require(amt > 0, "Nothing to claim");
        claimable[msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amt);
    }

    function _transferOrCredit(address to, uint256 amountRaw) internal {
        if (amountRaw == 0) return;
        require(to != address(0), "Zero address");
        IERC20 t = IERC20(token);
        try t.transfer(to, amountRaw) returns (bool success) {
            if (!success) {
                claimable[to] += amountRaw;
                emit CreditAccrued(to, amountRaw);
            }
        } catch {
            claimable[to] += amountRaw;
            emit CreditAccrued(to, amountRaw);
        }
    }

    // This function allows the owner to recover ERC20 tokens sent to the contract in case of trapped tokens.
    function recoverERC20(address _token, uint256 amt) external onlyOwner nonReentrant {
        IERC20(_token).safeTransfer(owner(), amt);
    }
}
