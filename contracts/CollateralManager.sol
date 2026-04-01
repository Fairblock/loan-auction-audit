// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interface/IOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/* 
 * @title CollateralManager
 * @dev This contract manages the locking and unlocking of collateral tokens for bidders.
 */
contract CollateralManager is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    event Locked(address indexed user, address indexed token, uint256 amount);
    event Unlocked(address indexed user, address indexed token, uint256 amount);
    event MaintenanceRatioSet(address indexed token, uint256 ratioBP);
    event ManagerSet(address manager);
    event CollateralTokenAdded(address token);
    event CollateralCreditAccrued(
        address indexed to,
        address indexed token,
        uint256 amount
    );

    IOracle public oracle;
    address public manager;
    mapping(address => uint256) public initialCollateralRatios;
    mapping(address => mapping(address => uint256)) private _locked;
    mapping(address => uint256) public maintenanceRatios;
    address[] public acceptedCollateralTokens;
    mapping(address => bool) public isAcceptedCollateral;
    mapping(address => uint8) public tokenDecimals;
    /// @notice Credited when direct ERC-20 transfer fails (user => token => amount).
    mapping(address => mapping(address => uint256)) public claimable;

    constructor(address _oracle) Ownable(msg.sender) {
        require(_oracle != address(0), "Invalid oracle");
        oracle = IOracle(_oracle);
    }

    modifier onlyAuthorized() {
        require(
            msg.sender == owner() || msg.sender == manager,
            "Not authorized"
        );
        _;
    }

    // This function sets the bid manager address.
    function setManager(address _manager) external onlyOwner {
        require(_manager != address(0), "Zero address");
        manager = _manager;
        emit ManagerSet(_manager);
    }

    // This function allows the bid manager to transfer collateral from one user to another.
    function transfer(
        address from,
        address to,
        address token,
        uint256 amount
    ) external onlyAuthorized nonReentrant {
        require(_locked[from][token] >= amount, "Insufficient locked");
        _locked[from][token] -= amount;

        _transferOrCredit(to, token, amount);
    }

    // View locked balance of a user for a specific token.
    function lockedBalance(
        address user,
        address token
    ) external view returns (uint256) {
        return _locked[user][token];
    }

    // This function allows the bid manager to lock collateral for a bidder.
    function lock(
        address user,
        address token,
        uint256 amount
    ) external onlyAuthorized nonReentrant {
        require(isAcceptedCollateral[token], "Token not accepted");
        require(amount > 0, "Insufficient amount");
        _locked[user][token] += amount;
        IERC20(token).safeTransferFrom(user, address(this), amount);
       
        emit Locked(user, token, amount);
    }

    // This function allows the bid manager to unlock collateral for a bidder.
    function unlock(
        address user,
        address token,
        uint256 amount
    ) external onlyAuthorized nonReentrant {
        require(_locked[user][token] >= amount, "Insufficient locked");
        _locked[user][token] -= amount;
        _transferOrCredit(user, token, amount);
        emit Unlocked(user, token, amount);
    }

    // This function is used to set the maintenance ratio for a specific token.
    function setMaintenanceRatio(
        address token,
        uint256 ratioBP
    ) external onlyOwner {
        require(ratioBP > 0, "Ratio 0");
        maintenanceRatios[token] = ratioBP;
        emit MaintenanceRatioSet(token, ratioBP);
    }

    // This function is used to add a new accepted collateral token.
    function addAcceptedCollateralToken(
        address token,
        uint256 initialRatio
    ) external onlyOwner nonReentrant {
        require(!isAcceptedCollateral[token], "Already accepted");
        isAcceptedCollateral[token] = true;
        acceptedCollateralTokens.push(token);
        initialCollateralRatios[token] = initialRatio;
        tokenDecimals[token] = IERC20Metadata(token).decimals();
        emit CollateralTokenAdded(token);
    }
    
    // View accepted collateral tokens.
    function getAcceptedCollateralTokens()
        external
        view
        returns (address[] memory)
    {
        return acceptedCollateralTokens;
    }

    // View the balance of a specific token for a user.
    function collateralBalanceOf(
        address user,
        address token
    ) external view returns (uint256) {
        return _locked[user][token];
    }

    // Set the oracle address.
    function setOracle(address _oracle) external onlyOwner nonReentrant {
        require(_oracle != address(0), "Zero address");
        oracle = IOracle(_oracle);
    }

    /// @notice Pull collateral previously credited after a failed transfer.
    function claim(address tokenAddr) external nonReentrant {
        uint256 amt = claimable[msg.sender][tokenAddr];
        require(amt > 0, "Nothing to claim");
        claimable[msg.sender][tokenAddr] = 0;
        IERC20(tokenAddr).safeTransfer(msg.sender, amt);
    }

    function _transferOrCredit(
        address to,
        address tokenAddr,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        require(to != address(0), "Zero address");
        IERC20 t = IERC20(tokenAddr);
        try t.transfer(to, amount) returns (bool success) {
            if (!success) {
                claimable[to][tokenAddr] += amount;
                emit CollateralCreditAccrued(to, tokenAddr, amount);
            }
        } catch {
            claimable[to][tokenAddr] += amount;
            emit CollateralCreditAccrued(to, tokenAddr, amount);
        }
    }
}
