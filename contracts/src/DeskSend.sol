// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAUSD {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function nonces(address owner) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @title DeskSend
/// @notice Moves a wallet's AUSD where the wallet said, with somebody else paying Monad's gas.
///         The wallet signs two things off-chain: an AUSD permit for this contract, and a Send
///         that pins the exact calls to run with that money. Anyone may submit the pair (Desk's
///         relayer does); nobody can change where the money goes. The calls may only touch AUSD
///         itself, to hand it to a recipient on Monad, or Relay's contracts, to send it to the
///         recipient on another chain. Whatever a call leaves behind goes back to the wallet in
///         the same transaction, so this contract never holds anything between calls.
/// @dev A Send is tied to the permit through AUSD's own nonce: the permit consumes the nonce,
///      so a Send can run once. There is no owner, no storage and nothing to upgrade.
contract DeskSend {
    IAUSD public constant AUSD = IAUSD(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
    /// @notice Relay's ERC-20 depository on Monad, the spender and target its quotes name.
    address public constant RELAY_DEPOSITORY = 0x4cD00E387622C35bDDB9b4c962C136462338BC31;
    /// @notice Relay's router, the same address on every chain, for routes that use it instead.
    address public constant RELAY_ROUTER = 0xCcC88a9d1B4ED6b0EABA998850414b24f1c315bE;

    bytes32 public constant SEND_TYPEHASH =
        keccak256("Send(address from,uint256 amount,uint256 nonce,uint256 deadline,bytes32 callsHash,bytes32 destination)");
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 private constant HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    bytes4 private constant APPROVE = 0x095ea7b3;
    bytes4 private constant TRANSFER = 0xa9059cbb;

    struct Call {
        address to;
        bytes data;
    }

    struct Send {
        address from;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
        bytes32 callsHash;
        /// @dev Who it is for, as the app showed it: keccak256 of "<chain>:<recipient>". Not read
        ///      here; it binds the signature to what the person saw and names them in the log.
        bytes32 destination;
    }

    event Sent(address indexed from, uint256 amount, bytes32 indexed destination, uint256 returned);

    error Expired();
    error WrongNonce(uint256 expected);
    error WrongCalls();
    error BadSignature();
    error NotAllowed(address to);
    error CallFailed(uint256 index);

    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Desk Send"), keccak256("1"), block.chainid, address(this)));
    }

    /// @notice The calls a Send pins, hashed the way the app and the server hash them.
    function hashCalls(Call[] calldata calls) public pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < calls.length; i++) {
            packed = abi.encodePacked(packed, calls[i].to, keccak256(calls[i].data));
        }
        return keccak256(packed);
    }

    /// @notice What the wallet signs.
    function hashSend(Send calldata intent) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(
            SEND_TYPEHASH, intent.from, intent.amount, intent.nonce, intent.deadline, intent.callsHash, intent.destination))));
    }

    /// @notice Runs a Send: takes the AUSD with the permit, runs the pinned calls, returns the rest.
    /// @param signature The wallet's signature over hashSend(intent), 65 bytes r‖s‖v.
    /// @param v The permit's signature, over AUSD's own Permit for this contract, intent.amount and intent.deadline.
    function send(Send calldata intent, bytes calldata signature, uint8 v, bytes32 r, bytes32 s, Call[] calldata calls) external {
        if (block.timestamp > intent.deadline) revert Expired();
        uint256 nonce = AUSD.nonces(intent.from);
        if (nonce != intent.nonce) revert WrongNonce(nonce);
        if (hashCalls(calls) != intent.callsHash) revert WrongCalls();
        if (recover(hashSend(intent), signature) != intent.from) revert BadSignature();

        AUSD.permit(intent.from, address(this), intent.amount, intent.deadline, v, r, s);
        AUSD.transferFrom(intent.from, address(this), intent.amount);

        for (uint256 i = 0; i < calls.length; i++) {
            check(calls[i]);
            (bool ok,) = calls[i].to.call(calls[i].data);
            if (!ok) revert CallFailed(i);
        }

        uint256 left = AUSD.balanceOf(address(this));
        if (left > 0) AUSD.transfer(intent.from, left);
        emit Sent(intent.from, intent.amount, intent.destination, left);
    }

    /// @dev AUSD may be approved to Relay or handed to a recipient; Relay's contracts take any call.
    function check(Call calldata call) private pure {
        if (call.to == RELAY_DEPOSITORY || call.to == RELAY_ROUTER) return;
        if (call.to != address(AUSD) || call.data.length != 68) revert NotAllowed(call.to);
        bytes4 selector = bytes4(call.data[:4]);
        if (selector == TRANSFER) return;
        if (selector != APPROVE) revert NotAllowed(call.to);
        address spender = address(uint160(uint256(bytes32(call.data[4:36]))));
        if (spender != RELAY_DEPOSITORY && spender != RELAY_ROUTER) revert NotAllowed(spender);
    }

    function recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r = bytes32(signature[:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (v < 27) v += 27;
        if (uint256(s) > HALF_ORDER || (v != 27 && v != 28)) revert BadSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
