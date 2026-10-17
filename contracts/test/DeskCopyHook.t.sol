// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeskCopyHook} from "../src/DeskCopyHook.sol";

struct Call {
    address to;
    uint256 value;
    bytes data;
}

struct BatchedCall {
    Call[] calls;
    bool revertOnFailure;
}

struct Key {
    uint8 keyType;
    bytes publicKey;
}

interface ICalibur {
    function execute(BatchedCall memory batchedCall) external payable;
    function register(Key memory key) external;
    function update(bytes32 keyHash, uint256 settings) external;
    function revoke(bytes32 keyHash) external;
    function isRegistered(bytes32 keyHash) external view returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IAllowanceHolder {
    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory);
}

interface ISettler {
    struct AllowedSlippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    function execute(AllowedSlippage calldata slippage, bytes[] calldata actions, bytes32 zid)
        external
        payable
        returns (bool);
}

/// Runs against Monad mainnet: the Calibur every Desk wallet already delegates to, 0x's live
/// AllowanceHolder and Settler, real AUSD, and real quotes from Desk's own endpoint.
contract DeskCopyHookTest is Test {
    address constant CALIBUR = 0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00;
    address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant SETTLERS = 0x00000000000004533Fe15556B1E086BB1A72cEae;
    // Calibur reads callbacks from the low bits: 11110 is afterValidateUserOp, afterIsValidSignature,
    // beforeExecute and afterExecute.
    address constant HOOK_AT = 0xDe5C0000000000000000000000000000dC0B501e;

    uint256 constant OWNER_KEY = 0xA11CE;
    uint256 constant DESK_KEY = 0xDE5C;
    address owner;
    address desk;
    bytes32 deskKeyHash;
    DeskCopyHook hook;
    address settler;
    uint40 expiry;

    function setUp() public {
        vm.createSelectFork("monad");
        owner = vm.addr(OWNER_KEY);
        desk = vm.addr(DESK_KEY);
        vm.deal(desk, 10 ether);
        settler = abi.decode(_view(SETTLERS, abi.encodeWithSignature("ownerOf(uint256)", 2)), (address));

        deployCodeTo("DeskCopyHook.sol:DeskCopyHook", HOOK_AT);
        hook = DeskCopyHook(HOOK_AT);

        vm.signAndAttachDelegation(CALIBUR, OWNER_KEY);
        vm.etch(owner, abi.encodePacked(hex"ef0100", CALIBUR));
        // stdstore cannot find AUSD's balance slot, so the test wallet is funded from a holder.
        vm.prank(0xaD01C20d5886137e056775af56915de824c8fCe5);
        IERC20(AUSD).transfer(owner, 30e6);

        deskKeyHash = keccak256(abi.encode(uint8(2), keccak256(abi.encode(desk))));
        expiry = uint40(block.timestamp + 30 days);
        _ownerRuns(_setup(10e6, 12e6));
    }

    function _setup(uint128 perTrade, uint128 perDay) internal view returns (Call[] memory calls) {
        calls = new Call[](4);
        calls[0] = Call(address(0), 0, abi.encodeCall(ICalibur.register, (Key(2, abi.encode(desk)))));
        uint256 settings = uint256(uint160(HOOK_AT)) | (uint256(expiry) << 160);
        calls[1] = Call(address(0), 0, abi.encodeCall(ICalibur.update, (deskKeyHash, settings)));
        calls[2] = Call(HOOK_AT, 0, abi.encodeCall(DeskCopyHook.configure, (deskKeyHash, perTrade, perDay)));
        calls[3] = Call(AUSD, 0, abi.encodeCall(IERC20.approve, (HOLDER, type(uint256).max)));
    }

    function _ownerRuns(Call[] memory calls) internal {
        vm.prank(owner);
        ICalibur(owner).execute(BatchedCall(calls, true));
    }

    function _deskRuns(Call[] memory calls) internal {
        vm.prank(desk);
        ICalibur(owner).execute(BatchedCall(calls, true));
    }

    function _one(address to, bytes memory data) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(to, 0, data);
    }

    function _quote(string memory side, address token, string memory amount) internal returns (bytes memory) {
        string[] memory command = new string[](5);
        command[0] = "test/quote.sh";
        command[1] = vm.toString(owner);
        command[2] = side;
        command[3] = vm.toString(token);
        command[4] = amount;
        return vm.ffi(command);
    }

    function _exec(address token, uint256 amount, address target, address recipient, address buyToken, uint256 floor)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory settle = abi.encodeCall(
            ISettler.execute, (ISettler.AllowedSlippage(recipient, buyToken, floor), new bytes[](0), bytes32(0))
        );
        return abi.encodeCall(IAllowanceHolder.exec, (target, token, amount, payable(target), settle));
    }

    function _view(address to, bytes memory data) internal view returns (bytes memory output) {
        bool ok;
        (ok, output) = to.staticcall(data);
        require(ok, "view failed");
    }

    function _buyFive() internal returns (uint256 received) {
        uint256 before = IERC20(WMON).balanceOf(owner);
        _deskRuns(_one(HOLDER, _quote("buy", WMON, "5")));
        received = IERC20(WMON).balanceOf(owner) - before;
    }

    // --- What the key may do --------------------------------------------------------------

    function test_hookSitsAtItsCallbackBits() public pure {
        assertEq(uint160(HOOK_AT) & 0x1F, 0x1E);
    }

    function test_copiesABuyAndSellsBackWhatItBrought() public {
        uint256 ausdBefore = IERC20(AUSD).balanceOf(owner);
        uint256 received = _buyFive();
        assertGt(received, 0, "the buy pays the wallet");
        assertEq(IERC20(AUSD).balanceOf(owner), ausdBefore - 5e6, "spends exactly the copied amount");
        assertEq(hook.copied(owner, deskKeyHash, WMON), received, "remembers what the copy brought");
        assertEq(hook.remainingToday(owner, deskKeyHash), 7e6);

        string memory amount = _readable(received, 18);
        Call[] memory calls = new Call[](2);
        calls[0] = Call(WMON, 0, abi.encodeCall(IERC20.approve, (HOLDER, received)));
        calls[1] = Call(HOLDER, 0, _quote("sell", WMON, amount));
        _deskRuns(calls);
        assertEq(hook.copied(owner, deskKeyHash, WMON), 0);
        assertGt(IERC20(AUSD).balanceOf(owner), ausdBefore - 5e6 + 4e6, "the sale pays AUSD back to the wallet");
    }

    // --- Spending limits ------------------------------------------------------------------

    function test_refusesAboveThePerTradeLimit() public {
        bytes memory buy = _exec(AUSD, 10e6 + 1, settler, owner, WMON, 1);
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.OverTradeLimit.selector, 10e6 + 1, 10e6));
        _deskRuns(_one(HOLDER, buy));
    }

    function test_refusesAboveTheDayLimit() public {
        _buyFive();
        bytes memory buy = _exec(AUSD, 8e6, settler, owner, WMON, 1);
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.OverDayLimit.selector, 13e6, 12e6));
        _deskRuns(_one(HOLDER, buy));
    }

    function test_theDayLimitResetsTheNextDay() public {
        _buyFive();
        vm.warp(block.timestamp + 1 days);
        assertEq(hook.remainingToday(owner, deskKeyHash), 12e6);
    }

    function test_zeroLimitsStopEveryBuy() public {
        _ownerRuns(_one(HOOK_AT, abi.encodeCall(DeskCopyHook.configure, (deskKeyHash, 0, 0))));
        bytes memory buy = _exec(AUSD, 1, settler, owner, WMON, 1);
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.OverTradeLimit.selector, 1, 0));
        _deskRuns(_one(HOLDER, buy));
    }

    // --- Where the money goes -------------------------------------------------------------

    function test_refusesASwapPayingSomeoneElse() public {
        address thief = makeAddr("thief");
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.NotToWallet.selector, thief));
        _deskRuns(_one(HOLDER, _exec(AUSD, 1e6, settler, thief, WMON, 1)));
    }

    function test_refusesAnythingButTheLiveSettler() public {
        address fake = makeAddr("fake settler");
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.NotSettler.selector, fake));
        _deskRuns(_one(HOLDER, _exec(AUSD, 1e6, fake, owner, WMON, 1)));
    }

    function test_refusesASwapWithNoFloor() public {
        vm.expectRevert(DeskCopyHook.NoFloor.selector);
        _deskRuns(_one(HOLDER, _exec(AUSD, 1e6, settler, owner, WMON, 0)));
    }

    function test_refusesSellingWhatTheCopyDidNotBuy() public {
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.NotCopied.selector, WMON, 1, 0));
        _deskRuns(_one(HOLDER, _exec(WMON, 1, settler, owner, AUSD, 1)));
    }

    function test_refusesSellingMoreThanTheCopyBought() public {
        uint256 received = _buyFive();
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.NotCopied.selector, WMON, received + 1, received));
        _deskRuns(_one(HOLDER, _exec(WMON, received + 1, settler, owner, AUSD, 1)));
    }

    function test_sellsOnlyForAUSD() public {
        uint256 received = _buyFive();
        vm.expectRevert(abi.encodeWithSelector(DeskCopyHook.SellsForAUSDOnly.selector, address(0x1234)));
        _deskRuns(_one(HOLDER, _exec(WMON, received, settler, owner, address(0x1234), 1)));
    }

    // --- Everything else is refused -------------------------------------------------------

    function test_refusesATransfer() public {
        vm.expectRevert(DeskCopyHook.NotAllowed.selector);
        _deskRuns(_one(AUSD, abi.encodeCall(IERC20.transfer, (desk, 1))));
    }

    function test_refusesAnApprovalToAnyoneButTheHolder() public {
        vm.expectRevert(DeskCopyHook.NotAllowed.selector);
        _deskRuns(_one(AUSD, abi.encodeCall(IERC20.approve, (desk, type(uint256).max))));
    }

    function test_refusesApprovingATokenTheCopyNeverBought() public {
        vm.expectRevert(DeskCopyHook.NotAllowed.selector);
        _deskRuns(_one(WMON, abi.encodeCall(IERC20.approve, (HOLDER, 1))));
    }

    function test_refusesSendingMON() public {
        vm.deal(owner, 20 ether);
        Call[] memory calls = new Call[](1);
        calls[0] = Call(desk, 1 ether, "");
        vm.expectRevert(DeskCopyHook.SendsValue.selector);
        _deskRuns(calls);
    }

    function test_refusesChangingItsOwnLimits() public {
        vm.expectRevert(DeskCopyHook.NotAllowed.selector);
        _deskRuns(_one(HOOK_AT, abi.encodeCall(DeskCopyHook.configure, (deskKeyHash, type(uint128).max, type(uint128).max))));
    }

    function test_refusesManagingTheWallet() public {
        Call[] memory calls = _one(address(0), abi.encodeCall(ICalibur.revoke, (deskKeyHash)));
        vm.expectRevert(bytes4(keccak256("OnlyAdminCanSelfCall()")));
        _deskRuns(calls);
    }

    function test_neverSignsForTheWallet() public {
        vm.expectRevert(DeskCopyHook.NoSignatures.selector);
        hook.afterIsValidSignature(deskKeyHash, bytes32(0), "");
    }

    // --- The wallet stays in charge -------------------------------------------------------

    function test_stopsWhenTheKeyExpires() public {
        vm.warp(uint256(expiry) + 1);
        bytes memory buy = _exec(AUSD, 1e6, settler, owner, WMON, 1);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        _deskRuns(_one(HOLDER, buy));
    }

    function test_stopsWhenTheWalletRevokesIt() public {
        _ownerRuns(_one(address(0), abi.encodeCall(ICalibur.revoke, (deskKeyHash))));
        assertFalse(ICalibur(owner).isRegistered(deskKeyHash));
        bytes memory buy = _exec(AUSD, 1e6, settler, owner, WMON, 1);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        _deskRuns(_one(HOLDER, buy));
    }

    function test_anotherWalletsCallsTouchOnlyItsOwnSlots() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        hook.afterExecute(deskKeyHash, true, "", abi.encode(WMON, uint256(0), uint256(0)));
        assertEq(hook.copied(owner, deskKeyHash, WMON), 0);
    }

    function _readable(uint256 raw, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 fraction = raw % unit;
        if (fraction == 0) return vm.toString(raw / unit);
        bytes memory digits = bytes(vm.toString(fraction + unit));
        bytes memory out = new bytes(decimals);
        for (uint256 i = 0; i < decimals; i++) out[i] = digits[i + 1];
        return string.concat(vm.toString(raw / unit), ".", string(out));
    }
}
