// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/StdUtils.sol";
import "forge-std/StdCheats.sol";
import "forge-std/StdJson.sol";
import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { ISeaportDeleverage } from "./interfaces/ISeaportDeleverage.sol";
import { ISpotOracle } from "./interfaces/ISpotOracle.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IUFDMHandler } from "./interfaces/IUFDMHandler.sol";
import { WadRayMath } from "@ionprotocol/libraries/math/WadRayMath.sol";
import { OrderType, ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ItemType,
    OfferItem,
    ConsiderationItem,
    Order,
    OrderParameters,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

using WadRayMath for uint256;
using stdJson for string;

struct TestJson {
    string key;
}

struct TOfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

contract HourglassDeleverage is Script, StdCheats {
    address public seaportDeleverageAddress = 0x045dB163d222BdD8295ca039CD0650D46AC477f3;
    address public seaportAddress = 0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC; // seaport 1.5

    // We need to prank the a user that has a borrow position in the ION weETH pool
    // Find potential borrowers here: https://etherscan.io/address/0x0000000000eaEbd95dAfcA37A39fd09745739b78#events
    address public ionBorrower = 0xa0f75491720835b36edC92D06DDc468D201e9b73;

    // tx: 0x45da0474cc67c5d067c79400789a7564c8643a46be3dbb92c12ed42a86353e79
    uint8 public ilkIndex = 0; // index for wstETH
    // Pool address for weETH pool
    address public ionPoolAddress = 0x0000000000eaEbd95dAfcA37A39fd09745739b78;
    address public ionPoolGem = 0x3f6119B0328C27190bE39597213ea1729f061876;
    // address public weethHandlerAddress = 0xAB3c6236327FF77159B37f18EF85e8AC58034479;
    address public wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public weeth = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    uint256 public newWstethBalance = 1000 ether; // enough to fully repay position

    IIonPool public ionPool;
    IGemJoin public gemJoin;
    IUFDMHandler public weethHandler;
    ISpotOracle public spotOracle;
    ISeaportDeleverage public seaportDeleverage;

    uint256 public ilkSpot;
    uint256 public ilkRate;

    function formatUnits(uint256 value, uint256 precision) public pure returns (string memory) {
        uint256 base = 10 ** precision;
        uint256 integerPart = value / base;
        uint256 fractionalPart = value % base;
        return string(abi.encodePacked(vm.toString(integerPart), ".", vm.toString(fractionalPart)));
    }

    function _parseSignature(string memory json) internal pure returns (bytes memory signature) {
        bytes memory sigJson = json.parseRaw(".signature");
        signature = abi.decode(sigJson, (bytes));
    }

    function _parseOfferItem0(string memory json) internal pure returns (OfferItem memory oi) {
        oi.itemType = ItemType.ERC20;
        oi.token = abi.decode(json.parseRaw(".components.offer[0].token"), (address));
        string memory identifierOrCriteriaStr =
            abi.decode(json.parseRaw(".components.offer[0].identifierOrCriteria"), (string));
        oi.identifierOrCriteria = vm.parseUint(identifierOrCriteriaStr);
        string memory startAmountStr = abi.decode(json.parseRaw(".components.offer[0].startAmount"), (string));
        oi.startAmount = vm.parseUint(startAmountStr);
        string memory endAmountStr = abi.decode(json.parseRaw(".components.offer[0].endAmount"), (string));
        oi.endAmount = vm.parseUint(endAmountStr);
    }

    function _parseConsiderationItem0(string memory json) internal pure returns (ConsiderationItem memory ci0) {
        ci0.itemType = ItemType.ERC20;
        ci0.token = abi.decode(json.parseRaw(".components.consideration[0].token"), (address));
        string memory identifierOrCriteriaStr =
            abi.decode(json.parseRaw(".components.consideration[0].identifierOrCriteria"), (string));
        ci0.identifierOrCriteria = vm.parseUint(identifierOrCriteriaStr);
        string memory startAmountStr = abi.decode(json.parseRaw(".components.consideration[0].startAmount"), (string));
        ci0.startAmount = vm.parseUint(startAmountStr);
        string memory endAmountStr = abi.decode(json.parseRaw(".components.consideration[0].endAmount"), (string));
        ci0.endAmount = vm.parseUint(endAmountStr);
        ci0.recipient = payable(abi.decode(json.parseRaw(".components.consideration[0].recipient"), (address)));
    }

    function _parseConsiderationItem1(string memory json) internal pure returns (ConsiderationItem memory ci1) {
        ci1.itemType = ItemType.ERC20;
        ci1.token = abi.decode(json.parseRaw(".components.consideration[1].token"), (address));
        string memory identifierOrCriteriaStr =
            abi.decode(json.parseRaw(".components.consideration[1].identifierOrCriteria"), (string));
        ci1.identifierOrCriteria = vm.parseUint(identifierOrCriteriaStr);
        string memory startAmountStr = abi.decode(json.parseRaw(".components.consideration[1].startAmount"), (string));
        ci1.startAmount = vm.parseUint(startAmountStr);
        string memory endAmountStr = abi.decode(json.parseRaw(".components.consideration[1].endAmount"), (string));
        ci1.endAmount = vm.parseUint(endAmountStr);
        ci1.recipient = payable(abi.decode(json.parseRaw(".components.consideration[1].recipient"), (address)));
    }

    function _parseRemainingOrderItems(string memory json)
        internal
        pure
        returns (
            address offerer,
            address zone,
            OrderType orderType,
            uint256 startTime,
            uint256 endTime,
            bytes32 zoneHash,
            uint256 salt,
            bytes32 conduitKey
        )
    {
        offerer = abi.decode(json.parseRaw(".components.offerer"), (address));
        zone = abi.decode(json.parseRaw(".components.zone"), (address));
        // orderType = abi.decode(json.parseRaw(".components.orderType"), (uint256));
        orderType = OrderType.FULL_RESTRICTED;
        startTime = abi.decode(json.parseRaw(".components.startTime"), (uint256));
        endTime = abi.decode(json.parseRaw(".components.endTime"), (uint256));
        zoneHash = abi.decode(json.parseRaw(".components.zoneHash"), (bytes32));
        string memory saltStr = abi.decode(json.parseRaw(".components.salt"), (string));
        salt = vm.parseUint(saltStr);
        conduitKey = abi.decode(json.parseRaw(".components.conduitKey"), (bytes32));
        // string memory counterStr = abi.decode(json.parseRaw(".components.counter"), (string));
        // counter = vm.parseUint(counterStr);
    }

    function _getOrderParams(string memory json) internal returns (OrderParameters memory orderParams) {
        orderParams.offer = new OfferItem[](1);
        orderParams.consideration = new ConsiderationItem[](2);

        orderParams.offer[0] = _parseOfferItem0(json);
        orderParams.consideration[0] = _parseConsiderationItem0(json);
        orderParams.consideration[1] = _parseConsiderationItem1(json);

        (
            orderParams.offerer,
            orderParams.zone,
            orderParams.orderType,
            orderParams.startTime,
            orderParams.endTime,
            orderParams.zoneHash,
            orderParams.salt,
            orderParams.conduitKey
        ) = _parseRemainingOrderItems(json);
    }

    function _getOrder() internal returns (Order memory order) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/data/seaport-order.json");
        string memory json = vm.readFile(path);

        OrderParameters memory orderParams = _getOrderParams(json);
        bytes memory signature = _parseSignature(json);
        order = Order({ parameters: orderParams, signature: signature });
    }

    function run() public {
        // proxy address for ION pool for weETH
        ionPool = IIonPool(ionPoolAddress);
        gemJoin = IGemJoin(ionPoolGem);
        seaportDeleverage = ISeaportDeleverage(seaportDeleverageAddress);

        vm.startPrank(ionBorrower);

        console2.log("address(this): ", address(this));
        console2.log("User: ", ionBorrower);
        console2.log("------------------------------------------------");

        spotOracle = ionPool.spot(ilkIndex);
        ilkSpot = spotOracle.getSpot(); // spot oracle for collateral with index `ilkIndex`.
        ilkRate = ionPool.rate(ilkIndex); // The rate (debt accumulator) for collateral with index `ilkIndex`.
        uint256 vaultNormalizedDebt0 = ionPool.normalizedDebt(ilkIndex, ionBorrower); // denominated in wstETH
        uint256 vaultCollateral0 = ionPool.collateral(ilkIndex, ionBorrower); // denominated in weETH

        console2.log("ilk spot: ", formatUnits(ilkSpot, 27));
        console2.log("ilk rate: ", formatUnits(ilkRate, 27));

        console2.log("-------------- Pre Interaction State -----------------");

        console2.log("vault normalized debt: ", formatUnits(vaultNormalizedDebt0, 18));
        console2.log("vault collateral: ", formatUnits(vaultCollateral0, 18));
        uint256 maxCollateralWithdrawable0 = vaultCollateral0 - (ilkRate * vaultNormalizedDebt0) / ilkSpot - 1; // -1
        console2.log("max collateral withdrawable: ", formatUnits(maxCollateralWithdrawable0, 18));

        console2.log("-------------- Seaport Order Details -----------------");

        Order memory order = _getOrder();

        console2.log("Offerer: ", order.parameters.offerer);
        console2.log("Zone: ", order.parameters.zone);
        console2.log("Order Type: ", uint256(order.parameters.orderType));
        console2.log("Start Time: ", order.parameters.startTime);
        console2.log("End Time: ", order.parameters.endTime);
        console2.log("Zone Hash: ", vm.toString(order.parameters.zoneHash));
        console2.log("Salt: ", order.parameters.salt);
        console2.log("Conduit Key: ", vm.toString(order.parameters.conduitKey));
        console2.log("Total Original Consideration Items: ", order.parameters.totalOriginalConsiderationItems);

        for (uint256 i = 0; i < order.parameters.offer.length; i++) {
            if (i == 0) {
                console2.log("Offer Items: ");
            }
            console2.log("-- Item ", i, ": ");
            console2.log("---- Item Type: ", uint256(order.parameters.offer[i].itemType));
            console2.log("---- Token: ", order.parameters.offer[i].token);
            console2.log("---- Identifier Or Criteria: ", order.parameters.offer[i].identifierOrCriteria);
            console2.log("---- Start Amount: ", order.parameters.offer[i].startAmount);
            console2.log("---- End Amount: ", order.parameters.offer[i].endAmount);
        }

        for (uint256 i = 0; i < order.parameters.consideration.length; i++) {
            if (i == 0) {
                console2.log("Consideration Items: ");
            }
            console2.log("-- Item ", i, ": ");
            console2.log("---- Item Type: ", uint256(order.parameters.consideration[i].itemType));
            console2.log("---- Token: ", order.parameters.consideration[i].token);
            console2.log("---- Identifier Or Criteria: ", order.parameters.consideration[i].identifierOrCriteria);
            console2.log("---- Start Amount: ", order.parameters.consideration[i].startAmount);
            console2.log("---- End Amount: ", order.parameters.consideration[i].endAmount);
            console2.log("---- Recipient: ", order.parameters.consideration[i].recipient);
        }
        console2.log("Signature: ", vm.toString(order.signature));

        vm.stopPrank();

        console2.log("-------------- User Performs Seaport Deleverage (100 wstETH delever) -----------------");

        IERC20 WSTETH = IERC20(wsteth);
        IERC20 WEETH = IERC20(weeth);

        // ------------------------ Setup state for the market maker ------------------------
        vm.startPrank(order.parameters.offerer);

        // Market maker is the offerer, give them requisite amount of offer item, and approve seaport to use
        address marketMaker = order.parameters.offerer;
        uint256 requiredWsteth = order.parameters.offer[0].startAmount;
        deal(address(wsteth), marketMaker, newWstethBalance);
        WSTETH.approve(address(seaportAddress), ~uint256(0));

        console2.log("Market maker address: ", marketMaker);
        console2.log("Market maker balance wstETH: ", formatUnits(WSTETH.balanceOf(marketMaker), 18));
        console2.log("Market maker allowance wstETH: ", formatUnits(WSTETH.allowance(marketMaker, seaportAddress), 18));

        vm.stopPrank();

        // ------------------------ Setup state for the ion borrower ------------------------
        vm.startPrank(ionBorrower);

        // Market maker is the offerer, approve seaport to use weETH
        WSTETH.approve(address(seaportAddress), ~uint256(0));

        console2.log("Ion borrower address: ", ionBorrower);
        console2.log("Ion borrower balance weETH: ", formatUnits(WEETH.balanceOf(ionBorrower), 18));
        console2.log("Ion borrower allowance weETH: ", formatUnits(WEETH.allowance(ionBorrower, seaportAddress), 18));

        // ------------------------ Execute the Order ------------------------

        seaportDeleverage.deleverage(
            order, order.parameters.consideration[1].startAmount, order.parameters.offer[0].startAmount
        );

        vm.stopPrank();
    }
}
