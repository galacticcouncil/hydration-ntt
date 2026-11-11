// SPDX-License-Identifier: Apache 2
pragma solidity >=0.8.8 <0.9.0;

import "forge-std/Test.sol";

import "../src/NttManager/NttManager.sol";
import "../src/NttManager/NttManagerWithPayload.sol";
import "../src/Transceiver/Transceiver.sol";
import "../src/interfaces/IManagerBase.sol";
import "../src/interfaces/IRateLimiter.sol";
import "../src/libraries/PausableUpgradeable.sol";
import "../src/libraries/TransceiverStructs.sol";
import "../src/mocks/DummyToken.sol";

import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "wormhole-solidity-sdk/Utils.sol";

/// @dev Transceiver that records the outbound manager message and delivers inbound
///      messages as if they came from `SOURCE_CHAIN_ID`.
contract CapturingTransceiver is Transceiver {
    uint16 constant SOURCE_CHAIN_ID = 1;
    bytes4 constant TEST_TRANSCEIVER_PAYLOAD_PREFIX = 0x99455454;

    bytes public lastMessage;

    constructor(
        address nttManager
    ) Transceiver(nttManager) {}

    function getTransceiverType() external pure override returns (string memory) {
        return "capturing";
    }

    function _quoteDeliveryPrice(
        uint16, /* recipientChain */
        TransceiverStructs.TransceiverInstruction memory /* transceiverInstruction */
    ) internal pure override returns (uint256) {
        return 0;
    }

    function _sendMessage(
        uint16, /* recipientChain */
        uint256, /* deliveryPayment */
        address, /* caller */
        bytes32, /* recipientNttManagerAddress */
        bytes32, /* refundAddress */
        TransceiverStructs.TransceiverInstruction memory, /* instruction */
        bytes memory nttManagerMessage
    ) internal override {
        lastMessage = nttManagerMessage;
    }

    function receiveMessage(
        bytes memory encodedMessage
    ) external {
        (
            TransceiverStructs.TransceiverMessage memory parsedTransceiverMessage,
            TransceiverStructs.NttManagerMessage memory parsedNttManagerMessage
        ) = TransceiverStructs.parseTransceiverAndNttManagerMessage(
            TEST_TRANSCEIVER_PAYLOAD_PREFIX, encodedMessage
        );
        _deliverToNttManager(
            SOURCE_CHAIN_ID,
            parsedTransceiverMessage.sourceNttManagerAddress,
            parsedTransceiverMessage.recipientNttManagerAddress,
            parsedNttManagerMessage
        );
    }
}

/// @dev Integrator contract calling the manager, like IntentEmitter does.
contract PayloadCaller {
    function send(
        NttManagerWithPayload manager,
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        bytes memory payload
    ) external returns (uint64) {
        IERC20(manager.token()).transferFrom(msg.sender, address(this), amount);
        IERC20(manager.token()).approve(address(manager), amount);
        return manager.transferWithPayload(amount, recipientChain, recipient, payload);
    }
}

contract TestNttManagerWithPayload is Test {
    using TrimmedAmountLib for TrimmedAmount;

    // source mirrors Hydration (burning spoke), destination mirrors the hub (locking)
    uint16 constant SOURCE_CHAIN_ID = 1;
    uint16 constant DEST_CHAIN_ID = 2;
    uint64 constant RATE_LIMIT_DURATION = 1 days;
    bytes4 constant TEST_TRANSCEIVER_PAYLOAD_PREFIX = 0x99455454;
    // prefix(4) + decimals(1) + amount(8) + sourceToken(32) + to(32) + toChain(2), no length field
    uint256 constant STOCK_NTT_LENGTH = 79;

    DummyTokenMintAndBurn sourceToken;
    DummyToken destToken;
    NttManagerWithPayload source;
    NttManager dest;
    CapturingTransceiver sourceTransceiver;
    CapturingTransceiver destTransceiver;

    address user = address(0x123);
    address recipient = address(0x456);
    uint256 amount;

    function setUp() public {
        sourceToken = new DummyTokenMintAndBurn();
        destToken = new DummyToken();
        amount = 5 * 10 ** sourceToken.decimals();

        source =
            NttManagerWithPayload(address(new ERC1967Proxy(address(_sourceImplementation()), "")));
        source.initialize();
        sourceTransceiver = new CapturingTransceiver(address(source));
        source.setTransceiver(address(sourceTransceiver));

        dest = NttManager(
            address(
                new ERC1967Proxy(
                    address(
                        new NttManager(
                            address(destToken),
                            IManagerBase.Mode.LOCKING,
                            DEST_CHAIN_ID,
                            RATE_LIMIT_DURATION,
                            false
                        )
                    ),
                    ""
                )
            )
        );
        dest.initialize();
        destTransceiver = new CapturingTransceiver(address(dest));
        dest.setTransceiver(address(destTransceiver));

        source.setPeer(DEST_CHAIN_ID, toWormholeFormat(address(dest)), 18, type(uint64).max);
        dest.setPeer(SOURCE_CHAIN_ID, toWormholeFormat(address(source)), 18, type(uint64).max);

        sourceToken.mintDummy(user, amount);
        destToken.mintDummy(address(dest), amount);
        vm.prank(user);
        sourceToken.approve(address(source), type(uint256).max);
    }

    function _sourceImplementation() internal returns (NttManagerWithPayload) {
        return new NttManagerWithPayload(
            address(sourceToken),
            IManagerBase.Mode.BURNING,
            SOURCE_CHAIN_ID,
            RATE_LIMIT_DURATION,
            false
        );
    }

    function _intentPayload() internal view returns (bytes memory) {
        return abi.encodePacked(bytes4(0x494e5401), abi.encode(recipient, uint256(1e15)));
    }

    function _transferWithPayload(
        uint256 value,
        bytes memory payload
    ) internal returns (uint64) {
        vm.prank(user);
        return
            source.transferWithPayload(value, DEST_CHAIN_ID, toWormholeFormat(recipient), payload);
    }

    function _lastSent()
        internal
        view
        returns (
            TransceiverStructs.NttManagerMessage memory m,
            TransceiverStructs.NativeTokenTransfer memory ntt
        )
    {
        m = TransceiverStructs.parseNttManagerMessage(sourceTransceiver.lastMessage());
        ntt = TransceiverStructs.parseNativeTokenTransfer(m.payload);
    }

    function _deliverToDest() internal {
        (, bytes memory encoded) = TransceiverStructs.buildAndEncodeTransceiverMessage(
            TEST_TRANSCEIVER_PAYLOAD_PREFIX,
            toWormholeFormat(address(source)),
            toWormholeFormat(address(dest)),
            sourceTransceiver.lastMessage(),
            new bytes(0)
        );
        destTransceiver.receiveMessage(encoded);
    }

    function test_transferWithPayload_encodesPayload() public {
        bytes memory payload = _intentPayload();
        uint64 seq = _transferWithPayload(amount, payload);

        (
            TransceiverStructs.NttManagerMessage memory m,
            TransceiverStructs.NativeTokenTransfer memory ntt
        ) = _lastSent();
        assertEq(m.id, bytes32(uint256(seq)));
        assertEq(m.sender, toWormholeFormat(user));
        assertEq(ntt.additionalPayload, payload);
        assertEq(ntt.to, toWormholeFormat(recipient));
        assertEq(ntt.toChain, DEST_CHAIN_ID);
        assertEq(ntt.sourceToken, toWormholeFormat(address(sourceToken)));
        assertEq(ntt.amount.untrim(18), amount);

        assertEq(sourceToken.balanceOf(user), 0);
        assertEq(sourceToken.totalSupply(), 0, "burning mode should burn");
    }

    function test_transferWithPayload_viaIntegratorContract() public {
        PayloadCaller caller = new PayloadCaller();
        bytes memory payload = _intentPayload();

        vm.startPrank(user);
        sourceToken.approve(address(caller), amount);
        caller.send(source, amount, DEST_CHAIN_ID, toWormholeFormat(recipient), payload);
        vm.stopPrank();

        (
            TransceiverStructs.NttManagerMessage memory m,
            TransceiverStructs.NativeTokenTransfer memory ntt
        ) = _lastSent();
        assertEq(m.sender, toWormholeFormat(address(caller)));
        assertEq(ntt.additionalPayload, payload);
    }

    function test_transfer_keepsStockWireFormat() public {
        _transferWithPayload(amount / 2, _intentPayload());

        vm.prank(user);
        source.transfer(amount / 2, DEST_CHAIN_ID, toWormholeFormat(recipient));

        (
            TransceiverStructs.NttManagerMessage memory m,
            TransceiverStructs.NativeTokenTransfer memory ntt
        ) = _lastSent();
        assertEq(ntt.additionalPayload.length, 0);
        assertEq(m.payload.length, STOCK_NTT_LENGTH);
    }

    function test_completeOutboundQueuedTransfer_keepsStockWireFormat() public {
        source.setOutboundLimit(amount / 2);

        vm.prank(user);
        uint64 seq = source.transfer(
            amount,
            DEST_CHAIN_ID,
            toWormholeFormat(recipient),
            toWormholeFormat(user),
            true,
            new bytes(1)
        );
        assertEq(sourceTransceiver.lastMessage().length, 0, "transfer should be queued");

        vm.warp(block.timestamp + RATE_LIMIT_DURATION + 1);
        source.completeOutboundQueuedTransfer(seq);

        (
            TransceiverStructs.NttManagerMessage memory m,
            TransceiverStructs.NativeTokenTransfer memory ntt
        ) = _lastSent();
        assertEq(ntt.additionalPayload.length, 0);
        assertEq(m.payload.length, STOCK_NTT_LENGTH);
    }

    function test_transferWithPayload_emptyPayloadMatchesPlainTransfer() public {
        _transferWithPayload(amount, "");

        (TransceiverStructs.NttManagerMessage memory m,) = _lastSent();
        assertEq(m.payload.length, STOCK_NTT_LENGTH);
    }

    function test_transferWithPayload_roundTrip() public {
        _transferWithPayload(amount, _intentPayload());
        (TransceiverStructs.NttManagerMessage memory m,) = _lastSent();

        _deliverToDest();

        // the stock destination manager ignores the payload and releases the funds
        assertEq(destToken.balanceOf(recipient), amount);
        assertEq(destToken.balanceOf(address(dest)), 0);
        bytes32 digest = TransceiverStructs.nttManagerMessageDigest(SOURCE_CHAIN_ID, m);
        assertTrue(dest.isMessageExecuted(digest));

        // the payload is bound to the attested digest
        TransceiverStructs.NativeTokenTransfer memory tampered =
            TransceiverStructs.parseNativeTokenTransfer(m.payload);
        tampered.additionalPayload = abi.encodePacked(bytes4(0x494e5401), abi.encode(user, 0));
        m.payload = TransceiverStructs.encodeNativeTokenTransfer(tampered);
        assertFalse(
            dest.isMessageExecuted(TransceiverStructs.nttManagerMessageDigest(SOURCE_CHAIN_ID, m))
        );
    }

    function test_transferWithPayload_revertsInsteadOfQueueing() public {
        source.setOutboundLimit(amount / 2);
        uint256 capacity = source.getCurrentOutboundCapacity();

        vm.expectRevert(
            abi.encodeWithSelector(IRateLimiter.NotEnoughCapacity.selector, capacity, amount)
        );
        _transferWithPayload(amount, _intentPayload());
    }

    function test_transferWithPayload_revertsWhenPaused() public {
        source.pause();
        vm.expectRevert(
            abi.encodeWithSelector(PausableUpgradeable.RequireContractIsNotPaused.selector)
        );
        _transferWithPayload(amount, _intentPayload());
    }

    function test_transferWithPayload_revertsWhenPayloadTooLong() public {
        // one byte over the limit that still fits the transceiver message
        uint256 len = 65389;
        vm.expectRevert(abi.encodeWithSelector(TransceiverStructs.PayloadTooLong.selector, len));
        _transferWithPayload(amount, new bytes(len));
    }

    function test_transferWithPayload_maxPayloadFitsTransceiverMessage() public {
        _transferWithPayload(amount, new bytes(65388));

        // the wrapping a real transceiver applies (e.g. WormholeTransceiver._sendMessage)
        bytes memory nttManagerMessage = sourceTransceiver.lastMessage();
        assertEq(nttManagerMessage.length, type(uint16).max);
        TransceiverStructs.encodeTransceiverMessage(
            TEST_TRANSCEIVER_PAYLOAD_PREFIX,
            TransceiverStructs.TransceiverMessage(
                toWormholeFormat(address(source)),
                toWormholeFormat(address(dest)),
                nttManagerMessage,
                new bytes(0)
            )
        );
    }

    function test_upgradeFromStandardManager() public {
        // a standard manager in production, upgraded in place to the payload variant
        NttManager standard = NttManager(
            address(
                new ERC1967Proxy(
                    address(
                        new NttManager(
                            address(sourceToken),
                            IManagerBase.Mode.BURNING,
                            SOURCE_CHAIN_ID,
                            RATE_LIMIT_DURATION,
                            false
                        )
                    ),
                    ""
                )
            )
        );
        standard.initialize();
        CapturingTransceiver transceiver = new CapturingTransceiver(address(standard));
        standard.setTransceiver(address(transceiver));
        standard.setPeer(DEST_CHAIN_ID, toWormholeFormat(address(dest)), 18, type(uint64).max);

        vm.startPrank(user);
        sourceToken.approve(address(standard), type(uint256).max);
        standard.transfer(amount / 2, DEST_CHAIN_ID, toWormholeFormat(recipient));
        vm.stopPrank();

        standard.upgrade(address(_sourceImplementation()));
        NttManagerWithPayload upgraded = NttManagerWithPayload(address(standard));

        assertEq(upgraded.getPeer(DEST_CHAIN_ID).peerAddress, toWormholeFormat(address(dest)));
        assertEq(upgraded.nextMessageSequence(), 1);

        bytes memory payload = _intentPayload();
        vm.prank(user);
        uint64 seq = upgraded.transferWithPayload(
            amount / 2, DEST_CHAIN_ID, toWormholeFormat(recipient), payload
        );
        assertEq(seq, 1);

        TransceiverStructs.NttManagerMessage memory m =
            TransceiverStructs.parseNttManagerMessage(transceiver.lastMessage());
        assertEq(TransceiverStructs.parseNativeTokenTransfer(m.payload).additionalPayload, payload);
    }

    function testFuzz_transferWithPayload(
        bytes memory payload
    ) public {
        vm.assume(payload.length <= 1024);
        _transferWithPayload(amount, payload);

        (, TransceiverStructs.NativeTokenTransfer memory ntt) = _lastSent();
        assertEq(ntt.additionalPayload, payload);

        _deliverToDest();
        assertEq(destToken.balanceOf(recipient), amount);
    }
}
