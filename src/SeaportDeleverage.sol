// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { WadRayMath } from "@ionprotocol/libraries/math/WadRayMath.sol";

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SeaportInterface } from "seaport-types/src/interfaces/SeaportInterface.sol";
import { Order, OrderParameters, OfferItem, ConsiderationItem } from "seaport-types/src/lib/ConsiderationStructs.sol";
import { ItemType, OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";

using WadRayMath for uint256;

/**
 * @title Seaport Deleverage
 * @notice A contract to leverage or deleverage a position on Ion Protocol using
 * RFQ swaps facilitated by Seaport.
 *
 * @dev The standard Seaport flow would go as follows:
 * 
 *      1. An `offerrer` creates an `Order` and signs it. The `fulfiller` will
 *      be given both the `Order` payload and the `signature`. The `fulfiller`'s
 *      role is to execute the transaction.
 *      
 *      Inside an `Order`, there is
 *       - an `offerer`: the signature that will be `ecrecover()`ed to verify
 *       the integrity of the signature.
 *       - an array of `Offer`s: Each `Offer` will have a token and an amount.
 *       - an array of `Consideration`s: Each `Consideration` will have a token,
 *       an amount and a recipient.
 *      
 *      2. Seaport will verify the signature was signed by the `offerer`.
 *      
 *      3. Seaport will iterate through all the `Offer`s and transfer the
 *      specified amount of each token to the fulfiller from the offerer.
 *      
 *      4. Seaport will iterate through all the `Consideration`s and transfer
 *      the specified amount of each token from the fulfiller to the recipient.
 * 
 * For the (de)leverage use-case, it is unideal that steps 3 and 4 must happen
 * in order because it means `Offer` items cannot be used before satisfying
 * `Consideration` constraints. Consider the deleverage case where debt must
 * first be repaid in the IonPool, before the collateral can be removed. If the
 * debt must be repaid before retrieving collateral from IonPool AND, on the
 * Seaport side, collateral must be paid before receiving the counterparty, then
 * a flashloan must be used. Ideally, Seaport would allow use of the
 * counterparty's collateral before checking the Consideration `constraints`.
 * 
 * While this would not be possible in the standard Seaport flow, we engage in a
 * non-standard flow that hijacks the ERC20 `transferFrom()` to gain control
 * flow in between steps 3 and 4. Normally, if the `offerer` wanted to sign for
 * a trade between 100 Token A and 90 Token B, the `Order` payload would contain
 * an `Offer` of 100 Token A and a `Consideration` of 90 Token B to the
 * `offerer`'s address.
 * 
 * However, to sign for the same trade to be executed through this contract, the
 * `Order` payload would still contain an `Offer` of 100 Token A. However, the
 * first `Consideration` would pass this contract address as the token address
 * (and the amount would be used to pass some other data) and the second
 * `Consideration` would pass the aforementioned 90 Token B to the `offerer`'s
 * address.
 * 
 * This allows this contract to gain control flow in between steps 3 and 4
 * through the `transferFrom()` function and Seaport still enforces the
 * `constraints` of the other `Consideration`s ensuring counterparty's terms.
 */
contract SeaportDeleverage {
    error InvalidContractConfigs(IIonPool pool, IGemJoin join);
    error DeleverageMustBeInitiated();
    error MsgSenderMustBeSeaport(address msgSender);

    // Order parameters head validation
    error OffersLengthMustBeOne(uint256 length);
    error ConsiderationsLengthMustBeTwo(uint256 length);
    error ZoneMustBeThis(address zone);
    error OrderTypeMustBeFullRestricted(OrderType orderType);
    error ZoneHashMustBeZero(bytes32 zoneHash);
    error ConduitKeyMustBeZero(bytes32 conduitKey);

    // Offer item validation
    error OItemTypeMustBeERC20(ItemType itemType);
    error OTokenMustBeBase(address token);
    error OStartMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error OEndMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);

    // Consideration item 1 validation
    error C1TypeMustBeERC20(ItemType itemType);
    error C1TokenMustBeThis(address token);
    error C1StartAmountMustBeDebtToRepay(uint256 startAmount, uint256 debtToRepay);
    error C1EndAmountMustBeDebtToRepay(uint256 endAmount, uint256 debtToRepay);
    error C1RecipientMustBeSender(address recipient);

    // Consideration item 2 validation
    error C2TypeMustBeERC20(ItemType itemType);
    error C2TokenMustBeCollateral(address token);
    error C2StartMustBeCollateralToRemove(uint256 startAmount, uint256 collateralToRemove);
    error C2EndMustBeCollateralToRemove(uint256 endAmount, uint256 collateralToRemove);

    uint256 private constant TSLOT_DELEVERAGE_INITIATED = 0;
    uint256 private constant TSLOT_COLLATERAL_TO_REMOVE = 1;

    modifier onlyReentrant() {
        uint256 deleverageInitiated;

        assembly {
            deleverageInitiated := tload(TSLOT_DELEVERAGE_INITIATED)
        }

        if (deleverageInitiated == 0) revert DeleverageMustBeInitiated();
        _;
    }

    SeaportInterface public constant SEAPORT = SeaportInterface(0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC);
    IIonPool public immutable POOL;
    IGemJoin public immutable JOIN;

    IERC20 public immutable BASE;
    IERC20 public immutable COLLATERAL;

    constructor(IIonPool pool, IGemJoin gemJoin) {
        POOL = pool;
        JOIN = gemJoin;

        if (gemJoin.POOL() != address(pool)) {
            revert InvalidContractConfigs(pool, gemJoin);
        }
        if (!pool.hasRole(pool.GEM_JOIN_ROLE(), address(gemJoin))) {
            revert InvalidContractConfigs(pool, gemJoin);
        }

        BASE = IERC20(pool.underlying());
        COLLATERAL = IERC20(gemJoin.GEM());

        BASE.approve(address(SEAPORT), type(uint256).max);
        COLLATERAL.approve(address(SEAPORT), type(uint256).max);
        BASE.approve(address(POOL), type(uint256).max);
    }

    /**
     * @notice Deleverage a position on `IonPool` through Seaport.
     * 
     * @dev 
     * ```solidity
     * struct Order {
     *      OrderParameters parameters;
     *      bytes signature;
     * }
     *
     * struct OrderParameters {
     *      address offerer; // 0x00
     *      address zone; // 0x20
     *      OfferItem[] offer; // 0x40
     *      ConsiderationItem[] consideration; // 0x60
     *      OrderType orderType; // 0x80
     *      uint256 startTime; // 0xa0
     *      uint256 endTime; // 0xc0
     *      bytes32 zoneHash; // 0xe0
     *      uint256 salt; // 0x100
     *      bytes32 conduitKey; // 0x120
     *      uint256 totalOriginalConsiderationItems; // 0x140
     * }
     *
     *
     * struct OfferItem {
     *      ItemType itemType;
     *      address token;
     *      uint256 identifierOrCriteria;
     *      uint256 startAmount;
     *      uint256 endAmount;
     * }
     *
     * struct ConsiderationItem {
     *      ItemType itemType;
     *      address token;
     *      uint256 identifierOrCriteria;
     *      uint256 startAmount;
     *      uint256 endAmount;
     *      address payable recipient;
     * }
     * ```
     * 
     * REQUIRES:
     * - There should only be one token for the `Offer`.
     * - There should be two items in the `Consideration`.
     * - The `zone` must be this contract's address. 
     * - The `orderType` must be `FULL_RESTRICTED`. This means only the `zone`,
     * or the offerer, can fulfill the order.
     * - The `conduitKey` must be zero. No conduit should be used.
     * 
     * - The `Offer` item must be of type `ERC20`.
     * - For the case of deleverage, `token` of the `Offer` item must be the
     * `BASE` token.
     * - The `startAmount` and `endAmount` of the `Offer` item must be equal to
     * `debtToRepay`. Start and end should be equal because the amount is fixed.
     * 
     * - The first `Consideration` item must be of type `ERC20`.
     * - The `token` of the first `Consideration` item must be this contract's
     * address. This is to allow this contract to gain control flow. We also
     * want to use the `transferFrom()` args to communicate data to the
     * `transferFrom()` callback. Any data that can't be fit into the
     * `transferFrom()` args will be communicated through transient storage.
     * - The `startAmount` and `endAmount` of the first `Consideration` item
     * communicate the amount of debt to repay to the callback.
     * 
     * The second `Consideration` item must be of type `ERC20`.
     * The `token` of the second `Consideration` item must be the `COLLATERAL`
     * The second `Consideration` item must have the `startAmount` and `endAmount`
     * equal to `collateralToRemove`.
     * 
     * @param order Seaport order.
     * @param collateralToRemove Amount of collateral to remove. [WAD]
     * @param debtToRepay Amount of debt to repay. [WAD]
     */
    function deleverage(Order calldata order, uint256 collateralToRemove, uint256 debtToRepay) external {
        OrderParameters calldata params = order.parameters;

        if (params.offer.length != 1) revert OffersLengthMustBeOne(params.offer.length);
        if (params.consideration.length != 2) revert ConsiderationsLengthMustBeTwo(params.consideration.length);
        if (params.zone != address(this)) revert ZoneMustBeThis(params.zone);
        if (params.orderType != OrderType.FULL_RESTRICTED) revert OrderTypeMustBeFullRestricted(params.orderType);
        if (params.conduitKey != bytes32(0)) revert ConduitKeyMustBeZero(params.conduitKey);

        OfferItem calldata offer1 = params.offer[0];

        if (offer1.itemType != ItemType.ERC20) revert OItemTypeMustBeERC20(offer1.itemType);
        if (offer1.token != address(BASE)) revert OTokenMustBeBase(offer1.token);
        if (offer1.startAmount != debtToRepay) revert OStartMustBeDebtToRepay(offer1.startAmount, debtToRepay);
        if (offer1.endAmount != debtToRepay) revert OEndMustBeDebtToRepay(offer1.endAmount, debtToRepay);

        ConsiderationItem calldata consideration1 = params.consideration[0];

        // forgefmt: disable-start
        if (consideration1.itemType != ItemType.ERC20) 
            revert C1TypeMustBeERC20(consideration1.itemType);
        if (consideration1.token != address(this)) 
            revert C1TokenMustBeThis(consideration1.token);
        if (consideration1.startAmount != debtToRepay) 
            revert C1StartAmountMustBeDebtToRepay(consideration1.startAmount, debtToRepay);
        if (consideration1.endAmount != debtToRepay) 
            revert C1EndAmountMustBeDebtToRepay(consideration1.endAmount, debtToRepay);
        if (consideration1.recipient != msg.sender) 
            revert C1RecipientMustBeSender(msg.sender);

        ConsiderationItem calldata consideration2 = params.consideration[1];
        
        if (consideration2.itemType != ItemType.ERC20) 
            revert C2TypeMustBeERC20(consideration2.itemType);
        if (consideration2.token != address(COLLATERAL)) 
            revert C2TokenMustBeCollateral(consideration2.token);
        if (consideration2.startAmount != collateralToRemove) 
            revert C2StartMustBeCollateralToRemove(consideration2.startAmount, collateralToRemove);
        if (consideration2.endAmount != collateralToRemove) 
            revert C2EndMustBeCollateralToRemove(consideration2.endAmount, collateralToRemove);
        // forgefmt: disable-end

        assembly {
            tstore(TSLOT_DELEVERAGE_INITIATED, 1)
            tstore(TSLOT_COLLATERAL_TO_REMOVE, collateralToRemove)
        }

        SEAPORT.fulfillOrder(order, bytes32(0));

        // Maintain composability :/
        assembly {
            tstore(TSLOT_DELEVERAGE_INITIATED, 0)
            tstore(TSLOT_COLLATERAL_TO_REMOVE, 0)
        }
    }

    /**
     * @notice This callback is not meant to be called directly.
     * 
     * @dev This function has nothing to do with `transferFrom()` despite its
     * name. This would be better described as a callback from Seaport to give
     * this contract control flow between the `Offer` being transferred and the
     * `Consideration` being transferred. We hijack the `transferFrom()`
     * selector to be able to use the default Seaport flow.
     * 
     * In order to enfore that this function is only called through a
     * transaction initiated by this contract, we use the `onlyReentrant`
     * modifier.
     * 
     * This function can only be called by the Seaport contract.
     * 
     * The second and the third arguments are used to communicate data necessary
     * for the callback context. Transient storage it used to communicate any
     * extra data that could not be fit into the `transferFrom()` args.
     * 
     * @param user whose position to modify on `IonPool`
     * @param debtToRepay amount of debt to repay on the `user`'s position
     */
    function transferFrom(address, address user, uint256 debtToRepay) external onlyReentrant {
        if (msg.sender != address(SEAPORT)) revert MsgSenderMustBeSeaport(msg.sender);

        uint256 collateralToRemove;
        assembly {
            collateralToRemove := tload(TSLOT_COLLATERAL_TO_REMOVE)
        }

        uint256 currentRate = POOL.rate(0);

        uint256 repayAmountNormalized = debtToRepay.rayDivDown(currentRate);

        POOL.repay(0, user, address(this), repayAmountNormalized);
        POOL.withdrawCollateral(0, user, address(this), collateralToRemove);
        JOIN.exit(address(this), collateralToRemove);
    }
}