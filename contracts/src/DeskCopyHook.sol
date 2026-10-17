// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Balance {
    function balanceOf(address owner) external view returns (uint256);
}

interface ISettlerDeployer {
    function ownerOf(uint256 tokenId) external view returns (address);
    function prev(uint128 featureId) external view returns (address);
}

/// @title DeskCopyHook
/// @notice The fence around Desk's copy key on a Calibur wallet. A wallet that turns on spot copying
///         registers Desk's key as a non-admin Calibur key with this hook, and the key can then do
///         exactly two things, both through 0x: spend the wallet's AUSD on a token, within the
///         per-trade and per-day limits the wallet set here, and sell back to AUSD only what such
///         buys brought in. Every swap pays out to the wallet itself. The key cannot transfer,
///         approve anyone but 0x's AllowanceHolder, sign for the wallet (ERC-1271), run as an
///         ERC-4337 signer, send MON, or touch tokens the wallet holds on its own.
/// @dev Calibur reads a hook's callbacks from the low bits of its address: this one must sit at an
///      address ending in binary 11110 (afterValidateUserOp, afterIsValidSignature, beforeExecute,
///      afterExecute; not afterVerifySignature). Storage is keyed by the calling wallet, so a call
///      from anyone else only ever reads or writes that caller's own slots.
contract DeskCopyHook {
    address public constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    ISettlerDeployer public constant SETTLERS = ISettlerDeployer(0x00000000000004533Fe15556B1E086BB1A72cEae);
    /// @notice Settler's taker-submitted feature in 0x's deployer: the one AllowanceHolder quotes use.
    uint128 public constant TAKER_SUBMITTED = 2;
    address public constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    bytes4 internal constant EXEC = 0x2213bc0b; // exec(address,address,uint256,address,bytes)
    bytes4 internal constant APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 internal constant SETTLER_EXECUTE = 0x1fff991f; // execute((address,address,uint256),bytes[],bytes32)

    struct Limits {
        uint128 perTrade;
        uint128 perDay;
    }

    struct Spent {
        uint64 day;
        uint192 amount;
    }

    mapping(address wallet => mapping(bytes32 keyHash => Limits)) public limits;
    mapping(address wallet => mapping(bytes32 keyHash => Spent)) public spent;
    /// @notice What copied buys brought into the wallet and the key may sell, per token.
    mapping(address wallet => mapping(bytes32 keyHash => mapping(address token => uint256))) public copied;

    event Configured(address indexed wallet, bytes32 indexed keyHash, uint128 perTrade, uint128 perDay);
    event Bought(address indexed wallet, bytes32 indexed keyHash, address indexed token, uint256 spent, uint256 received);
    event Sold(address indexed wallet, bytes32 indexed keyHash, address indexed token, uint256 amount);

    error NotAllowed();
    error SendsValue();
    error NotSettler(address target);
    error NotToWallet(address recipient);
    error NoFloor();
    error OverTradeLimit(uint256 amount, uint256 limit);
    error OverDayLimit(uint256 total, uint256 limit);
    error NotCopied(address token, uint256 amount, uint256 held);
    error SellsForAUSDOnly(address buyToken);
    error NoSignatures();
    error NoUserOperations();

    /// @notice Sets the wallet's limits for a key, in AUSD base units. Zero stops every buy. Only the
    ///         wallet itself can call this for itself; Desk's key is never let through to it.
    function configure(bytes32 keyHash, uint128 perTrade, uint128 perDay) external {
        limits[msg.sender][keyHash] = Limits(perTrade, perDay);
        emit Configured(msg.sender, keyHash, perTrade, perDay);
    }

    /// @notice The AUSD a key may still spend for the wallet today.
    function remainingToday(address wallet, bytes32 keyHash) external view returns (uint256) {
        Limits memory set = limits[wallet][keyHash];
        Spent memory today = spent[wallet][keyHash];
        uint256 used = today.day == block.timestamp / 1 days ? today.amount : 0;
        return used >= set.perDay ? 0 : set.perDay - used;
    }

    function beforeExecute(bytes32 keyHash, address to, uint256 value, bytes calldata data)
        external
        returns (bytes4, bytes memory)
    {
        if (value != 0) revert SendsValue();
        if (data.length < 4) revert NotAllowed();
        bytes4 selector = bytes4(data[:4]);

        if (to == ALLOWANCE_HOLDER && selector == EXEC) {
            return (this.beforeExecute.selector, _swap(keyHash, data));
        }
        if (selector == APPROVE && data.length == 68) {
            (address spender,) = abi.decode(data[4:], (address, uint256));
            if (spender != ALLOWANCE_HOLDER) revert NotAllowed();
            if (to != AUSD && copied[msg.sender][keyHash][to] == 0) revert NotAllowed();
            return (this.beforeExecute.selector, "");
        }
        revert NotAllowed();
    }

    function afterExecute(bytes32 keyHash, bool success, bytes calldata, bytes calldata context)
        external
        returns (bytes4)
    {
        if (success && context.length != 0) {
            (address token, uint256 before, uint256 paid) = abi.decode(context, (address, uint256, uint256));
            uint256 after_ = IERC20Balance(token).balanceOf(msg.sender);
            uint256 received = after_ > before ? after_ - before : 0;
            copied[msg.sender][keyHash][token] += received;
            emit Bought(msg.sender, keyHash, token, paid, received);
        }
        return this.afterExecute.selector;
    }

    /// @dev The key never signs for the wallet: no Permit2 permits, no off-chain orders, no logins.
    function afterIsValidSignature(bytes32, bytes32, bytes calldata) external pure returns (bytes4) {
        revert NoSignatures();
    }

    /// @dev Nor does it run user operations, which would pay their gas from the wallet's MON.
    function afterValidateUserOp(bytes32, PackedUserOperation calldata, bytes32, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NoUserOperations();
    }

    function _swap(bytes32 keyHash, bytes calldata data) private returns (bytes memory) {
        (address operator, address token, uint256 amount, address target, bytes memory settle) =
            abi.decode(data[4:], (address, address, uint256, address, bytes));
        if (operator != target || !_isSettler(target)) revert NotSettler(target);
        address buyToken = _payout(settle);
        return token == AUSD ? _buy(keyHash, amount, buyToken) : _sell(keyHash, token, amount, buyToken);
    }

    /// @dev Settler's `execute` starts with `AllowedSlippage(recipient, buyToken, minAmountOut)`, which
    ///      Settler enforces after the last action: at least the floor of the buy token to the recipient.
    function _payout(bytes memory settle) private view returns (address buyToken) {
        if (settle.length < 100 || bytes4(settle) != SETTLER_EXECUTE) revert NotAllowed();
        uint256 recipientWord;
        uint256 buyTokenWord;
        uint256 floor;
        assembly {
            recipientWord := mload(add(settle, 36))
            buyTokenWord := mload(add(settle, 68))
            floor := mload(add(settle, 100))
        }
        if (recipientWord >> 160 != 0 || buyTokenWord >> 160 != 0) revert NotAllowed();
        address recipient = address(uint160(recipientWord));
        if (recipient != msg.sender) revert NotToWallet(recipient);
        if (floor == 0) revert NoFloor();
        return address(uint160(buyTokenWord));
    }

    function _buy(bytes32 keyHash, uint256 amount, address buyToken) private returns (bytes memory) {
        if (buyToken == AUSD || buyToken.code.length == 0) revert NotAllowed();
        Limits memory set = limits[msg.sender][keyHash];
        if (amount > set.perTrade) revert OverTradeLimit(amount, set.perTrade);
        uint64 day = uint64(block.timestamp / 1 days);
        Spent storage today = spent[msg.sender][keyHash];
        uint256 total = (today.day == day ? today.amount : 0) + amount;
        if (total > set.perDay) revert OverDayLimit(total, set.perDay);
        today.day = day;
        today.amount = uint192(total);
        return abi.encode(buyToken, IERC20Balance(buyToken).balanceOf(msg.sender), amount);
    }

    function _sell(bytes32 keyHash, address token, uint256 amount, address buyToken) private returns (bytes memory) {
        if (buyToken != AUSD) revert SellsForAUSDOnly(buyToken);
        uint256 held = copied[msg.sender][keyHash][token];
        if (amount > held) revert NotCopied(token, amount, held);
        copied[msg.sender][keyHash][token] = held - amount;
        emit Sold(msg.sender, keyHash, token, amount);
        return "";
    }

    function _isSettler(address target) private view returns (bool) {
        if (target == SETTLERS.ownerOf(TAKER_SUBMITTED)) return true;
        try SETTLERS.prev(TAKER_SUBMITTED) returns (address previous) {
            return target == previous && previous != address(0);
        } catch {
            return false;
        }
    }
}

struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
