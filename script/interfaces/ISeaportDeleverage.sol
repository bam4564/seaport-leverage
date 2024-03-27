// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import {
    ItemType,
    OfferItem,
    ConsiderationItem,
    Order,
    OrderParameters,
    OrderComponents,
    ItemType,
    OrderType
} from "seaport-types/src/lib/ConsiderationStructs.sol";

interface ISeaportDeleverage {
    error C1EndAmountMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);
    error C1RecipientMustBeSender(address invalidRecipient);
    error C1StartAmountMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error C1TokenMustBeThis(address token);
    error C1TypeMustBeERC20(ItemType itemType);
    error C2EndMustBeCollateralToRemove(uint256 endAmount, uint256 collateralToRemove);
    error C2StartMustBeCollateralToRemove(uint256 startAmount, uint256 collateralToRemove);
    error C2TokenMustBeCollateral(address token);
    error C2TypeMustBeERC20(ItemType itemType);
    error ConduitKeyMustBeZero(bytes32 conduitKey);
    error ConsiderationsLengthMustBeTwo(uint256 length);
    error InvalidContractConfigs(address pool, address join);
    error InvalidTotalOriginalConsiderationItems();
    error MathOverflowedMulDiv();
    error MsgSenderMustBeSeaport(address msgSender);
    error NotACallback();
    error NotEnoughCollateral(uint256 collateralToRemove, uint256 currentCollateral);
    error OEndMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);
    error OItemTypeMustBeERC20(ItemType itemType);
    error OStartMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error OTokenMustBeBase(address token);
    error OffersLengthMustBeOne(uint256 length);
    error OrderTypeMustBeFullRestricted(OrderType orderType);
    error ZoneHashMustBeZero(bytes32 zoneHash);
    error ZoneMustBeThis(address zone);

    function BASE() external view returns (address);
    function COLLATERAL() external view returns (address);
    function ILK_INDEX() external view returns (uint8);
    function JOIN() external view returns (address);
    function POOL() external view returns (address);
    function SEAPORT() external view returns (address);
    function deleverage(Order memory order, uint256 collateralToRemove, uint256 debtToRepay) external;
    function seaportCallback4878572495(address, address user, uint256 debtToRepay) external;
}
