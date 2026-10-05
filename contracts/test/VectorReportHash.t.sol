// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {StakingManager} from "../src/StakingManager.sol";
import {BSY} from "../src/BSY.sol";
import {Report, Observation, BitSyncTypes} from "../src/BitSyncTypes.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Asserts Solidity digests + recoveries match the shared cross-language vector.
contract VectorReportHashTest is Test {
    using stdJson for string;

    function test_SharedVectorMatches() public {
        string memory raw = vm.readFile("../test-vectors/report_hash.json");
        uint256 chainId = raw.readUint(".chainId");
        address verifying = raw.readAddress(".verifyingContract");
        bytes32 feedId = raw.readBytes32(".feedId");
        int256 reportPrice = raw.readInt(".reportPrice");
        uint256 reportConfidence = raw.readUint(".reportConfidence");
        int256 obsPrice = raw.readInt(".observationPrice");
        uint256 obsConfidence = raw.readUint(".observationConfidence");
        uint64 timestamp = uint64(raw.readUint(".timestamp"));
        uint64 round = uint64(raw.readUint(".round"));
        bytes32 expectedReportDigest = raw.readBytes32(".reportDigest");
        bytes32 expectedObsDigest = raw.readBytes32(".observationDigest");
        address expectedSigner = raw.readAddress(".signer");
        bytes memory reportSig = raw.readBytes(".reportSignature");
        bytes memory obsSig = raw.readBytes(".observationSignature");
        bytes32 expectedReportTypehash = raw.readBytes32(".reportTypehash");
        bytes32 expectedObsTypehash = raw.readBytes32(".observationTypehash");

        assertEq(BitSyncTypes.REPORT_TYPEHASH, expectedReportTypehash);
        assertEq(BitSyncTypes.OBSERVATION_TYPEHASH, expectedObsTypehash);

        // Place a live OracleAggregator at the vector's verifyingContract so its
        // EIP-712 domain separator matches the shared vector exactly.
        vm.chainId(chainId);
        BSY bsy = new BSY(address(this));
        StakingManager staking = new StakingManager(address(bsy), address(this), 1 days, 1);
        OracleAggregator impl = new OracleAggregator(address(staking), address(this));
        vm.etch(verifying, address(impl).code);
        // The etched code still reads `staking` from its original storage slots;
        // digests only need the domain (name/version/chainId/address), which is
        // immutables baked into the bytecode — but `staking` is also immutable and
        // baked in, so digest calls work without storage. Call via the etched address.
        OracleAggregator oracle = OracleAggregator(verifying);

        Report memory report = Report(feedId, reportPrice, reportConfidence, timestamp, round);
        Observation memory obs = Observation(feedId, obsPrice, obsConfidence, timestamp, round);

        bytes32 reportDigest = oracle.reportDigest(report);
        bytes32 obsDigest = oracle.observationDigest(obs);
        assertEq(reportDigest, expectedReportDigest, "report digest mismatch");
        assertEq(obsDigest, expectedObsDigest, "observation digest mismatch");
        assertEq(ECDSA.recover(reportDigest, reportSig), expectedSigner);
        assertEq(ECDSA.recover(obsDigest, obsSig), expectedSigner);
    }
}
