// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AllianceToken} from "../src/AllianceToken.sol";

contract AllianceTokenTest is Test {
    AllianceToken internal token;
    address internal treasury = makeAddr("treasury");
    uint256 internal constant SUPPLY = 10_000_000_000 * 1e18;

    function setUp() public {
        token = new AllianceToken("NCTR", "NCTR", treasury);
    }

    // ---------- genesis ----------

    function test_TotalSupplyIsTenBillion() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_TreasuryHoldsAllAtGenesis() public view {
        assertEq(token.balanceOf(treasury), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0, "deployer holds nothing");
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_Metadata() public view {
        assertEq(token.name(), "NCTR");
        assertEq(token.symbol(), "NCTR");
        assertEq(token.decimals(), 18);
    }

    function test_RevertWhen_TreasuryIsZero() public {
        vm.expectRevert(AllianceToken.ZeroTreasury.selector);
        new AllianceToken("NCTR", "NCTR", address(0));
    }

    function testFuzz_GenesisForAnyTreasury(address t) public {
        vm.assume(t != address(0));
        AllianceToken x = new AllianceToken("A", "B", t);
        assertEq(x.balanceOf(t), SUPPLY);
        assertEq(x.totalSupply(), SUPPLY);
    }

    // ---------- no privileged surface ----------

    /// Any privileged selector must hit no function (the contract has no fallback, so it reverts).
    function test_NoOwnerOrAdminFunctionExists() public {
        bytes4[18] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("renounceOwnership()")),
            bytes4(keccak256("acceptOwnership()")),
            bytes4(keccak256("pendingOwner()")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("paused()")),
            bytes4(keccak256("grantRole(bytes32,address)")),
            bytes4(keccak256("hasRole(bytes32,address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("upgradeToAndCall(address,bytes)")),
            bytes4(keccak256("setFeesEnabled(bool)")),
            bytes4(keccak256("updateTaxes(uint256,uint256)"))
        ];
        for (uint256 i = 0; i < selectors.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), uint256(1)));
            assertFalse(ok, "privileged selector responded");
        }
    }

    function test_RejectsEther() public {
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
    }

    function test_NotAProxy() public view {
        // EIP-1967 implementation and admin slots are empty.
        bytes32 impl = vm.load(address(token), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        bytes32 admin = vm.load(address(token), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103);
        assertEq(impl, bytes32(0));
        assertEq(admin, bytes32(0));
    }

    // ---------- transfers ----------

    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != treasury);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(treasury);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(treasury), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferMoreThanBalanceReverts(address from, address to, uint256 amount) public {
        vm.assume(from != address(0) && from != treasury && to != address(0));
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert();
        token.transfer(to, amount);
    }

    function testFuzz_TransferFrom(address spender, address to, uint256 allowance_, uint256 amount) public {
        vm.assume(spender != address(0) && to != address(0) && to != treasury);
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, allowance_);
        vm.prank(treasury);
        token.approve(spender, allowance_);
        vm.prank(spender);
        token.transferFrom(treasury, to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.allowance(treasury, spender), allowance_ - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TrailingCalldataIsIgnoredByTransfer() public {
        // Migration transfers carry an ERC-8021 suffix after the ABI arguments.
        address to = makeAddr("member");
        bytes memory data = bytes.concat(
            abi.encodeCall(token.transfer, (to, 5e18)), hex"62635f39307735627078350b0080218021802180218021802180218021"
        );
        vm.prank(treasury);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertTrue(ok);
        assertTrue(abi.decode(ret, (bool)));
        assertEq(token.balanceOf(to), 5e18);
    }

    // ---------- permit ----------

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function testFuzz_PermitWorks(uint256 pk, address spender, uint256 value) public {
        pk = bound(pk, 1, 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        address owner = vm.addr(pk);
        vm.assume(spender != address(0));
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, spender, value, 0, deadline));
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }

    function test_PermitThenTransferFrom() public {
        (address owner, uint256 pk) = makeAddrAndKey("holder");
        address spender = makeAddr("spender");
        vm.prank(treasury);
        token.transfer(owner, 100e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, spender, 40e18, 0, deadline));
        token.permit(owner, spender, 40e18, deadline, v, r, s);
        vm.prank(spender);
        token.transferFrom(owner, spender, 40e18);
        assertEq(token.balanceOf(spender), 40e18);
        assertEq(token.balanceOf(owner), 60e18);
    }

    function test_RevertWhen_PermitExpired() public {
        (address owner, uint256 pk) = makeAddrAndKey("holder");
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, address(1), 1, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert();
        token.permit(owner, address(1), 1, deadline, v, r, s);
    }

    function test_RevertWhen_PermitReplayed() public {
        (address owner, uint256 pk) = makeAddrAndKey("holder");
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(owner, address(1), 1, 0, deadline));
        token.permit(owner, address(1), 1, deadline, v, r, s);
        vm.expectRevert();
        token.permit(owner, address(1), 1, deadline, v, r, s);
    }

    function test_RevertWhen_PermitWrongSigner() public {
        (address owner,) = makeAddrAndKey("holder");
        (, uint256 otherPk) = makeAddrAndKey("other");
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, _permitDigest(owner, address(1), 1, 0, deadline));
        vm.expectRevert();
        token.permit(owner, address(1), 1, deadline, v, r, s);
    }

    function test_DomainSeparatorUsesNameAndChain() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NCTR")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }
}
