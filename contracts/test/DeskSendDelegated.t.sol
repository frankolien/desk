// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeskSend, IAUSD} from "../src/DeskSend.sol";

/// A wallet that runs Calibur (EIP-7702, every spot-copy user) has code: AUSD's permit must still
/// take its key's signature, and a send must go through exactly as from a plain wallet.
contract DeskSendDelegatedTest is Test {
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant CALIBUR = 0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00;
    address constant HOLDER = 0xaD01C20d5886137e056775af56915de824c8fCe5;
    bytes32 constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 constant OWNER_KEY = 0xA11CE;
    uint256 constant AMOUNT = 6_890_000;
    address owner;
    DeskSend sender;
    uint256 deadline;

    function setUp() public {
        vm.createSelectFork("monad");
        owner = vm.addr(OWNER_KEY);
        sender = new DeskSend();
        vm.etch(owner, abi.encodePacked(hex"ef0100", CALIBUR));
        vm.prank(HOLDER);
        IAUSD(AUSD).transfer(owner, 10e6);
        deadline = block.timestamp + 120;
    }

    function _permit() internal view returns (uint8 v, bytes32 r, bytes32 s) {
        (, bytes memory out) = AUSD.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(sender), AMOUNT, IAUSD(AUSD).nonces(owner), deadline));
        return vm.sign(OWNER_KEY, keccak256(abi.encodePacked("\x19\x01", abi.decode(out, (bytes32)), structHash)));
    }

    function _relayCalls() internal returns (DeskSend.Call[] memory calls) {
        string[] memory command = new string[](7);
        command[0] = "test/relay-send.sh";
        command[1] = vm.toString(address(sender));
        command[2] = vm.toString(AMOUNT);
        command[3] = "792703809";
        command[4] = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
        command[5] = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";
        command[6] = vm.toString(owner);
        (address[] memory tos, bytes[] memory datas) = abi.decode(vm.ffi(command), (address[], bytes[]));
        calls = new DeskSend.Call[](tos.length);
        for (uint256 i = 0; i < tos.length; i++) calls[i] = DeskSend.Call(tos[i], datas[i]);
    }

    function _signed(DeskSend.Call[] memory calls) internal view returns (DeskSend.Send memory intent, bytes memory signature) {
        intent = DeskSend.Send(owner, AMOUNT, IAUSD(AUSD).nonces(owner), deadline, sender.hashCalls(calls), keccak256("x"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, sender.hashSend(intent));
        signature = abi.encodePacked(r, s, v);
    }

    function test_SendsToSolanaFromADelegatedWallet() public {
        DeskSend.Call[] memory calls = _relayCalls();
        (DeskSend.Send memory intent, bytes memory signature) = _signed(calls);
        (uint8 v, bytes32 r, bytes32 s) = _permit();
        vm.prank(address(0xDE5C));
        sender.send(intent, signature, v, r, s, calls);
        assertEq(IAUSD(AUSD).balanceOf(owner), 10e6 - AMOUNT);
    }

    function test_PermitFromADelegatedWallet() public {
        (uint8 v, bytes32 r, bytes32 s) = _permit();
        IAUSD(AUSD).permit(owner, address(sender), AMOUNT, deadline, v, r, s);
        assertEq(IAUSD(AUSD).nonces(owner), 1);
    }
}
