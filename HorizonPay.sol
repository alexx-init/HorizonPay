// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/proxy/utils/Initializable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HorizonPay
 * @notice Upgradeable payroll splitter for Tempo network
 * @dev Supports all ERC20 tokens + native ETH | Max 20 recipients
 *      0.3% platform fee goes directly to feeReceiver on every payment
 *      Upgradeable via UUPS proxy pattern
 */
contract HorizonPay is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ─── Constants ─────────────────────────────────────────────
    uint256 public constant PLATFORM_FEE_BPS = 30;      // 0.30%
    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant MAX_RECIPIENTS   = 20;
    address public constant ETH_ADDRESS      = address(0);
    string  public constant VERSION          = "1.0.0";

    // ─── State ─────────────────────────────────────────────────
    address public feeReceiver;
    uint256 public payrollCount;
    uint256 public totalVolume; // in USD cents approx

    struct Recipient {
        address wallet;
        uint256 bps;        // basis points (10000 = 100%)
        string  label;      // e.g. "Alice - Designer"
        bool    active;
    }

    struct PayrollConfig {
        uint256 id;
        string  name;
        address token;
        Recipient[] recipients;
        uint256 totalBps;
        bool    active;
        uint256 createdAt;
    }

    struct PayrollRecord {
        uint256 id;
        uint256 configId;
        uint256 amount;
        address token;
        uint256 fee;
        uint256 timestamp;
        uint256 recipientCount;
        string  note;
    }

    mapping(uint256 => PayrollConfig)  public configs;
    mapping(address => uint256[])      public ownerConfigs;
    mapping(uint256 => PayrollRecord[]) public payrollHistory;
    mapping(address => uint256)        public totalReceived; // per recipient

    uint256 public configCount;

    // ─── Events ────────────────────────────────────────────────
    event ConfigCreated  (uint256 indexed id, address indexed owner, string name);
    event ConfigUpdated  (uint256 indexed id);
    event PayrollSent    (uint256 indexed configId, uint256 indexed recordId, uint256 amount, address token, uint256 fee);
    event RecipientPaid  (uint256 indexed configId, address indexed recipient, uint256 amount, address token);
    event FeeReceiverSet (address oldReceiver, address newReceiver);

    // ─── Errors ────────────────────────────────────────────────
    error TooManyRecipients();
    error InvalidBPS();
    error TotalBPSExceeds();
    error ZeroAmount();
    error InvalidConfig();
    error InactiveConfig();
    error NotConfigOwner();
    error ZeroAddress();
    error TransferFailed();
    error WrongETHAmount();

    // ─── Initializer (replaces constructor for upgradeable) ────
    function initialize(address _feeReceiver) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        if (_feeReceiver == address(0)) revert ZeroAddress();
        feeReceiver = _feeReceiver;
    }

    // ─── Create Payroll Config ─────────────────────────────────
    function createConfig(
        string calldata name,
        address token,
        address[] calldata wallets,
        uint256[] calldata bpsArray,
        string[] calldata labels
    ) external returns (uint256 id) {
        if (wallets.length > MAX_RECIPIENTS)       revert TooManyRecipients();
        if (wallets.length != bpsArray.length)     revert InvalidBPS();
        if (wallets.length != labels.length)       revert InvalidBPS();

        uint256 totalBps;
        for (uint256 i; i < bpsArray.length; i++) {
            if (bpsArray[i] == 0)                  revert InvalidBPS();
            totalBps += bpsArray[i];
        }
        if (totalBps > BPS_DENOMINATOR)            revert TotalBPSExceeds();

        id = ++configCount;
        PayrollConfig storage cfg = configs[id];
        cfg.id        = id;
        cfg.name      = name;
        cfg.token     = token;
        cfg.totalBps  = totalBps;
        cfg.active    = true;
        cfg.createdAt = block.timestamp;

        for (uint256 i; i < wallets.length; i++) {
            cfg.recipients.push(Recipient({
                wallet: wallets[i],
                bps:    bpsArray[i],
                label:  labels[i],
                active: true
            }));
        }

        ownerConfigs[msg.sender].push(id);
        emit ConfigCreated(id, msg.sender, name);
    }

    // ─── Send Payroll ERC20 ────────────────────────────────────
    function sendPayrollERC20(
        uint256 configId,
        uint256 amount,
        string calldata note
    ) external nonReentrant {
        if (amount == 0)                           revert ZeroAmount();
        PayrollConfig storage cfg = _validateConfig(configId);

        uint256 fee       = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - fee;

        // Pull full amount from sender
        IERC20(cfg.token).safeTransferFrom(msg.sender, address(this), amount);

        // Send fee directly to feeReceiver
        if (fee > 0) {
            IERC20(cfg.token).safeTransfer(feeReceiver, fee);
        }

        // Split to all recipients
        for (uint256 i; i < cfg.recipients.length; i++) {
            Recipient storage r = cfg.recipients[i];
            if (!r.active) continue;
            uint256 share = (netAmount * r.bps) / cfg.totalBps;
            if (share > 0) {
                IERC20(cfg.token).safeTransfer(r.wallet, share);
                totalReceived[r.wallet] += share;
                emit RecipientPaid(configId, r.wallet, share, cfg.token);
            }
        }

        _recordPayroll(configId, amount, cfg.token, fee, note);
        emit PayrollSent(configId, payrollCount, amount, cfg.token, fee);
    }

    // ─── Send Payroll ETH ──────────────────────────────────────
    function sendPayrollETH(
        uint256 configId,
        string calldata note
    ) external payable nonReentrant {
        if (msg.value == 0)                        revert ZeroAmount();
        PayrollConfig storage cfg = _validateConfig(configId);
        if (cfg.token != ETH_ADDRESS)              revert InvalidConfig();

        uint256 fee       = (msg.value * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = msg.value - fee;

        // Send fee
        if (fee > 0) {
            (bool ok,) = feeReceiver.call{value: fee}("");
            if (!ok) revert TransferFailed();
        }

        // Split to recipients
        for (uint256 i; i < cfg.recipients.length; i++) {
            Recipient storage r = cfg.recipients[i];
            if (!r.active) continue;
            uint256 share = (netAmount * r.bps) / cfg.totalBps;
            if (share > 0) {
                (bool ok2,) = r.wallet.call{value: share}("");
                if (!ok2) revert TransferFailed();
                totalReceived[r.wallet] += share;
                emit RecipientPaid(configId, r.wallet, share, ETH_ADDRESS);
            }
        }

        _recordPayroll(configId, msg.value, ETH_ADDRESS, fee, note);
        emit PayrollSent(configId, payrollCount, msg.value, ETH_ADDRESS, fee);
    }

    // ─── Update Config ─────────────────────────────────────────
    function toggleConfig(uint256 configId, bool active) external {
        if (!_isConfigOwner(configId)) revert NotConfigOwner();
        configs[configId].active = active;
        emit ConfigUpdated(configId);
    }

    // ─── View Functions ────────────────────────────────────────
    function getConfig(uint256 id) external view returns (PayrollConfig memory) {
        return configs[id];
    }

    function getOwnerConfigs(address owner) external view returns (uint256[] memory) {
        return ownerConfigs[owner];
    }

    function getHistory(uint256 configId) external view returns (PayrollRecord[] memory) {
        return payrollHistory[configId];
    }

    function getRecipients(uint256 configId) external view returns (Recipient[] memory) {
        return configs[configId].recipients;
    }

    function calculateSplit(uint256 configId, uint256 amount) external view returns (
        address[] memory wallets,
        uint256[] memory amounts,
        uint256 fee
    ) {
        PayrollConfig storage cfg = configs[configId];
        fee = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = amount - fee;
        wallets  = new address[](cfg.recipients.length);
        amounts  = new uint256[](cfg.recipients.length);
        for (uint256 i; i < cfg.recipients.length; i++) {
            wallets[i] = cfg.recipients[i].wallet;
            amounts[i] = (net * cfg.recipients[i].bps) / cfg.totalBps;
        }
    }

    // ─── Owner Functions ───────────────────────────────────────
    function setFeeReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert ZeroAddress();
        emit FeeReceiverSet(feeReceiver, newReceiver);
        feeReceiver = newReceiver;
    }

    // ─── Internal ──────────────────────────────────────────────
    function _validateConfig(uint256 id) internal view returns (PayrollConfig storage cfg) {
        cfg = configs[id];
        if (cfg.id == 0)    revert InvalidConfig();
        if (!cfg.active)    revert InactiveConfig();
    }

    function _isConfigOwner(uint256 configId) internal view returns (bool) {
        uint256[] memory ids = ownerConfigs[msg.sender];
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == configId) return true;
        }
        return false;
    }

    function _recordPayroll(
        uint256 configId,
        uint256 amount,
        address token,
        uint256 fee,
        string calldata note
    ) internal {
        uint256 rid = ++payrollCount;
        payrollHistory[configId].push(PayrollRecord({
            id:             rid,
            configId:       configId,
            amount:         amount,
            token:          token,
            fee:            fee,
            timestamp:      block.timestamp,
            recipientCount: configs[configId].recipients.length,
            note:           note
        }));
    }

    receive() external payable {}

    // ─── Storage gap for future upgrades ───────────────────────
    uint256[50] private __gap;
}
