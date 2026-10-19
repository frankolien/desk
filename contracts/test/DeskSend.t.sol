// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeskSend, IAUSD} from "../src/DeskSend.sol";

/// Runs against Monad mainnet: the real AUSD and its permit, Relay's live depository, and a live
/// Relay route to Solana fetched for the very address the contract is deployed to.
contract DeskSendTest is Test {
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant HOLDER = 0xaD01C20d5886137e056775af56915de824c8fCe5;
    bytes32 constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 constant SOLANA = 792703809;
    string constant USDC_SOLANA = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    string constant FRIEND_ON_SOLANA = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";

    uint256 constant OWNER_KEY = 0xA11CE;
    address owner;
    address relayer = address(0xDE5C);
    address bob = address(0xB0B);
    DeskSend sender;

    function setUp() public {
        vm.createSelectFork("monad");
        owner = vm.addr(OWNER_KEY);
        vm.deal(relayer, 1 ether);
        // The same deterministic deploy as production: the factory, salt zero.
        bytes memory initCode = type(DeskSend).creationCode;
        address expected = vm.computeCreate2Address(bytes32(0), keccak256(initCode), FACTORY);
        vm.prank(relayer);
        (bool ok,) = FACTORY.call(abi.encodePacked(bytes32(0), initCode));
        require(ok && expected.code.length > 0, "deploy");
        sender = DeskSend(expected);
        vm.prank(HOLDER);
        IAUSD(AUSD).transfer(owner, 50e6);
    }

    // ---- helpers ----

    function _permit(uint256 amount, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(sender), amount, IAUSD(AUSD).nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _ausdDomain(), structHash));
        (v, r, s) = vm.sign(OWNER_KEY, digest);
    }

    function _ausdDomain() internal view returns (bytes32 separator) {
        (, bytes memory out) = AUSD.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        separator = abi.decode(out, (bytes32));
    }

    function _intent(uint256 amount, uint256 deadline, DeskSend.Call[] memory calls, bytes32 destination)
        internal view returns (DeskSend.Send memory intent, bytes memory signature)
    {
        intent = DeskSend.Send(owner, amount, IAUSD(AUSD).nonces(owner), deadline, _hash(calls), destination);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, sender.hashSend(intent));
        signature = abi.encodePacked(r, s, v);
    }

    function _hash(DeskSend.Call[] memory calls) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < calls.length; i++) packed = abi.encodePacked(packed, calls[i].to, keccak256(calls[i].data));
        return keccak256(packed);
    }

    function _transferCalls(address to, uint256 amount) internal pure returns (DeskSend.Call[] memory calls) {
        calls = new DeskSend.Call[](1);
        calls[0] = DeskSend.Call(AUSD, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _relayCalls(uint256 amount) internal returns (DeskSend.Call[] memory calls) {
        string[] memory command = new string[](7);
        command[0] = "test/relay-send.sh";
        command[1] = vm.toString(address(sender));
        command[2] = vm.toString(amount);
        command[3] = vm.toString(SOLANA);
        command[4] = USDC_SOLANA;
        command[5] = FRIEND_ON_SOLANA;
        command[6] = vm.toString(owner);
        (address[] memory tos, bytes[] memory datas) = abi.decode(vm.ffi(command), (address[], bytes[]));
        calls = new DeskSend.Call[](tos.length);
        for (uint256 i = 0; i < tos.length; i++) calls[i] = DeskSend.Call(tos[i], datas[i]);
    }

    function _send(DeskSend.Send memory intent, bytes memory signature, DeskSend.Call[] memory calls) internal {
        (uint8 v, bytes32 r, bytes32 s) = _permit(intent.amount, intent.deadline);
        vm.prank(relayer);
        sender.send(intent, signature, v, r, s, calls);
    }

    // ---- tests ----

    function test_SendsOnMonadWithoutTheWalletPayingGas() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = _transferCalls(bob, 20e6);
        (DeskSend.Send memory intent, bytes memory signature) = _intent(20e6, deadline, calls, keccak256("143:bob"));
        uint256 before = IAUSD(AUSD).balanceOf(owner);
        _send(intent, signature, calls);
        assertEq(IAUSD(AUSD).balanceOf(bob), 20e6);
        assertEq(IAUSD(AUSD).balanceOf(owner), before - 20e6);
        assertEq(IAUSD(AUSD).balanceOf(address(sender)), 0);
    }

    function test_SendsToSolanaThroughRelay() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = _relayCalls(20e6);
        assertEq(calls.length, 2, "approve and deposit");
        assertEq(calls[0].to, AUSD);
        assertEq(calls[1].to, sender.RELAY_DEPOSITORY());
        (DeskSend.Send memory intent, bytes memory signature) = _intent(20e6, deadline, calls, keccak256("792703809:9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"));
        uint256 before = IAUSD(AUSD).balanceOf(owner);
        uint256 depository = IAUSD(AUSD).balanceOf(sender.RELAY_DEPOSITORY());
        _send(intent, signature, calls);
        assertEq(IAUSD(AUSD).balanceOf(owner), before - 20e6);
        assertEq(IAUSD(AUSD).balanceOf(sender.RELAY_DEPOSITORY()), depository + 20e6, "the AUSD sits with Relay, for the solver to fill against");
        assertEq(IAUSD(AUSD).balanceOf(address(sender)), 0);
    }

    function test_LeftoverGoesBackToTheWallet() public {
        // The permit covers 20 but the pinned calls only move 15: the 5 come straight back.
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = _transferCalls(bob, 15e6);
        (DeskSend.Send memory intent, bytes memory signature) = _intent(20e6, deadline, calls, bytes32(0));
        uint256 before = IAUSD(AUSD).balanceOf(owner);
        _send(intent, signature, calls);
        assertEq(IAUSD(AUSD).balanceOf(owner), before - 15e6);
        assertEq(IAUSD(AUSD).balanceOf(address(sender)), 0);
    }

    function test_CannotRunTwice() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = _transferCalls(bob, 1e6);
        (DeskSend.Send memory intent, bytes memory signature) = _intent(1e6, deadline, calls, bytes32(0));
        (uint8 v, bytes32 r, bytes32 s) = _permit(1e6, deadline);
        vm.prank(relayer);
        sender.send(intent, signature, v, r, s, calls);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(DeskSend.WrongNonce.selector, intent.nonce + 1));
        sender.send(intent, signature, v, r, s, calls);
    }

    function test_RelayerCannotChangeTheCalls() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory signedFor = _transferCalls(bob, 1e6);
        (DeskSend.Send memory intent, bytes memory signature) = _intent(1e6, deadline, signedFor, bytes32(0));
        DeskSend.Call[] memory swapped = _transferCalls(relayer, 1e6);
        (uint8 v, bytes32 r, bytes32 s) = _permit(1e6, deadline);
        vm.prank(relayer);
        vm.expectRevert(DeskSend.WrongCalls.selector);
        sender.send(intent, signature, v, r, s, swapped);
    }

    function test_OnlyAUSDAndRelayMayBeCalled() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = new DeskSend.Call[](1);
        calls[0] = DeskSend.Call(AUSD, abi.encodeWithSelector(0x095ea7b3, relayer, 1e6)); // approve to a stranger
        (DeskSend.Send memory intent, bytes memory signature) = _intent(1e6, deadline, calls, bytes32(0));
        (uint8 v, bytes32 r, bytes32 s) = _permit(1e6, deadline);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(DeskSend.NotAllowed.selector, relayer));
        sender.send(intent, signature, v, r, s, calls);

        calls[0] = DeskSend.Call(bob, "");
        (intent, signature) = _intent(1e6, deadline, calls, bytes32(0));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(DeskSend.NotAllowed.selector, bob));
        sender.send(intent, signature, v, r, s, calls);
    }

    function test_SomebodyElsesSignatureIsRefused() public {
        uint256 deadline = block.timestamp + 120;
        DeskSend.Call[] memory calls = _transferCalls(bob, 1e6);
        DeskSend.Send memory intent = DeskSend.Send(owner, 1e6, IAUSD(AUSD).nonces(owner), deadline, _hash(calls), bytes32(0));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(0xBAD, sender.hashSend(intent));
        (uint8 v, bytes32 r, bytes32 s) = _permit(1e6, deadline);
        vm.prank(relayer);
        vm.expectRevert(DeskSend.BadSignature.selector);
        sender.send(intent, abi.encodePacked(r2, s2, v2), v, r, s, calls);
    }

    function test_ExpiredIsRefused() public {
        uint256 deadline = block.timestamp - 1;
        DeskSend.Call[] memory calls = _transferCalls(bob, 1e6);
        (DeskSend.Send memory intent, bytes memory signature) = _intent(1e6, deadline, calls, bytes32(0));
        (uint8 v, bytes32 r, bytes32 s) = _permit(1e6, deadline);
        vm.prank(relayer);
        vm.expectRevert(DeskSend.Expired.selector);
        sender.send(intent, signature, v, r, s, calls);
    }
}
