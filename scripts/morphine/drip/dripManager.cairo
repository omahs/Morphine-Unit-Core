%lang starknet

from starkware.starknet.common.syscalls import (
    get_tx_info,
    get_block_number,
    get_block_timestamp,
    get_contract_address,
    get_caller_address,
)
from starkware.cairo.common.math_cmp import is_le, is_nn, is_not_zero
from starkware.cairo.common.uint256 import Uint256, uint256_pow2
from starkware.cairo.common.uint256 import (
    uint256_sub,
    uint256_check,
    uint256_le,
    uint256_lt,
    uint256_eq,
    uint256_add,
)
from morphine.utils.utils import (
    felt_to_uint256,
    uint256_div,
    uint256_percent,
    uint256_mul_low,
    uint256_pow,
)
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.bitwise import bitwise_and, bitwise_xor, bitwise_or
from starkware.starknet.common.syscalls import deploy
from openzeppelin.token.erc20.IERC20 import IERC20
from openzeppelin.security.safemath.library import SafeUint256
from starkware.cairo.common.math import assert_not_zero
from openzeppelin.security.pausable.library import Pausable
from openzeppelin.security.reentrancyguard.library import ReentrancyGuard
from morphine.interfaces.IDrip import IDrip
from morphine.interfaces.IRegistery import IRegistery
from morphine.interfaces.IPool import IPool
from morphine.interfaces.IDripFactory import IDripFactory
from morphine.interfaces.IOracleTransit import IOracleTransit
from morphine.utils.RegisteryAccess import RegisteryAccess
from morphine.utils.safeerc20 import SafeERC20
from morphine.utils.various import PRECISION

/// @title Drip Manager
/// @author 0xSacha
/// @dev Contract Contract Managing Drip Infrastructure
/// @custom:experimental This is an experimental contract.

// Storage
@storage_var
func emergency_liquidation() -> (state: felt) {
}

@storage_var
func max_allowed_enabled_tokens_length() -> (max_allowed_enabled_tokens_length: Uint256) {
}

@storage_var
func drip_factory() -> (drip_factory: felt) {
}

@storage_var
func pool() -> (pool: felt) {
}

@storage_var
func oracle_transit() -> (oracle_transit: felt) {
}

@storage_var
func drip_transit() -> (drip_junction: felt) {
}

@storage_var
func drip_configurator() -> (drip_configurator: felt) {
}

@storage_var
func underlying_contract() -> (underlying_contract: felt) {
}

// Interest fee protocol charges: fee = interest accrues * feeInterest
@storage_var
func fee_interest() -> (fee_interest: Uint256) {
}

// Liquidation fee protocol charges: fee = totalValue * feeLiquidation
@storage_var
func fee_liqudidation() -> (fee_liqudidation: Uint256) {
}

// Multiplier to get amount which liquidator should pay: amount = totalValue * liquidationDiscount
@storage_var
func liquidation_discount() -> (liquidation_discount: Uint256) {
}

@storage_var
func fee_liqudidation_expired() -> (fee_liqudidation_expired: Uint256) {
}

@storage_var
func liquidation_discount_expired() -> (liquidation_discount_expired: Uint256) {
}

@storage_var
func borrower_to_drip(borrower: felt) -> (drip: felt) {
}

@storage_var
func token_from_mask(token_mask: Uint256) -> (token: felt) {
}

@storage_var
func liquidation_threshold_from_mask(token_mask: Uint256) -> (lt: Uint256) {
}

@storage_var
func allowed_tokens_length() -> (length: felt) {
}

@storage_var
func token_mask(token: felt) -> (mask: Uint256) {
}

@storage_var
func forbidden_token_mask() -> (mask: Uint256) {
}

@storage_var
func enabled_tokens(drip: felt) -> (mask: Uint256) {
}

@storage_var
func adapter_to_contract(adapter: felt) -> (contract: felt) {
}

@storage_var
func contract_to_adapter(adapter: felt) -> (contract: felt) {
}

@storage_var
func cumulative_drop(drip: felt) -> (cumulative_drop: Uint256) {
}

@storage_var
func can_liquidate_while_paused(liquidator: felt) -> (state: felt) {
}


// Protector

// @notice: Check if caller is drip configurator
func assert_only_drip_configurator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (caller_) = get_caller_address();
    let (drip_configurator_) = drip_configurator.read();
    with_attr error_message("only the configurator can call this function") {
        assert caller_ = drip_configurator_;
    }
    return();
}

// @notice: Check if caller is drip transit
func assert_only_drip_transit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (caller_) = get_caller_address();
    let (drip_transit_) = drip_transit.read();
    with_attr error_message("only callable by drip transit") {
        assert caller_ = drip_transit_;
    }
    return ();
}

// @notice: Check if not paused or caller is emergency liquidator
func assert_not_paused_or_emergency{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    let (is_paused_) = Pausable.is_paused();
    let (emergency_liquidation_) = emergency_liquidation.read();
    if(is_paused_ == 1){
        with_attr error_message("Pausable: paused") {
        assert emergency_liquidation_ = 1;
        }
        return();
    } else {
        return ();
    }
}


// @notice: Check if caller is drip transit or adapters
func assert_only_drip_transit_or_adapters{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    alloc_locals;
    let (caller_) = get_caller_address();
    let (adapter_to_contract_) = adapter_to_contract.read(caller_);

    let (is_not_adapter_) = is_equal(adapter_to_contract_, 0);
    let (drip_transit_) = drip_transit.read();

    with_attr error_message("only drip transit or adapter") {
        assert (is_not_adapter_ * (drip_transit_ - caller_)) = 0;
    }
    return();
}

// @notice: Contract Consutructor
// @dev: caller is now drip configurator
@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_pool: felt) {
    alloc_locals;
    with_attr error_message("pool is address zero") {
        assert_not_zero(_pool);
    }
    pool.write(_pool);
    let (registery_) = IPool.getRegistery(_pool);
    RegisteryAccess.initializer(registery_);

    let (underlying_) = IPool.asset(_pool);
    underlying_contract.write(underlying_);

    add_token(underlying_);

    let (oracle_transit_) = IRegistery.oracleTransit(registery_);
    oracle_transit.write(oracle_transit_);

    let (drip_factory_) = IRegistery.dripFactory(registery_);
    drip_factory.write(drip_factory_);

    let (drip_configurator_) = get_caller_address();
    drip_configurator.write(drip_configurator_);
    return ();
}

// @notice: Pause Contract
@external
func pause{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    RegisteryAccess.assert_only_owner();
    Pausable.assert_not_paused();
    Pausable._pause();
    return ();
}

// @notice: Unpause Contract
@external
func unpause{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    RegisteryAccess.assert_only_owner();
    Pausable.assert_paused();
    Pausable._unpause();
    return ();
}

// @notice: Set emergency liquidator while pause if caller allowed
@external 
func checkEmergencyPausable{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_caller: felt, _state: felt) -> (state: felt) {
    alloc_locals;
    assert_only_drip_transit();
    let (is_paused_) = Pausable.is_paused();
    let (can_liquidate_while_paused_) = can_liquidate_while_paused.read(_caller);
    let (is_zero_) = is_equal(can_liquidate_while_paused_ * is_paused_,0);
    if ( is_zero_ == 0) {
        emergency_liquidation.write(_state);
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    }
    return(is_paused_,);
}

// @notice: Open Drip
// @param: _borrowed_amount Borrowed Amount (Uint256)
// @param: _on_belhalf_of Open a drip on belahf of user (felt)
// @return: drip Drip address
@external
func openDrip{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrowed_amount: Uint256, _on_belhalf_of: felt
) -> (drip: felt) {
    alloc_locals;
    ReentrancyGuard.start();
    Pausable.assert_not_paused();
    assert_only_drip_transit();
    let (pool_) = pool.read();
    let (cumulative_index_) = IPool.calcLinearCumulativeIndex(pool_);
    let (drip_factory_) = drip_factory.read();
    let (drip_) = IDripFactory.takeDrip(drip_factory_, _borrowed_amount, cumulative_index_);
    IPool.borrow(pool_, _borrowed_amount, drip_);
    safe_drip_set(_on_belhalf_of, drip_);
    enabled_tokens.write(drip_, Uint256(1, 0));
    ReentrancyGuard.end();
    return (drip_,);
}

// @notice: Close Drip
// @param: _borrower Borrower (felt)
// @param _type 0 and other: ordinary closure type 1: liquidation, 2: drip expired liquidation, 3: pause liquidation (felt)
// @param: _total_value Total Drip value, liquidation case only (Uint256)
// @param: _payer Liquidator, can repay drip debt (felt)
// @param: _to Address to send funds (felt)
// @return: remainingFunds Remaining funds for borrower, liquidation case only (Uint256)
@external
func closeDrip{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _borrower: felt, _type: felt, _total_value: Uint256, _payer: felt, _to: felt
) -> (remainingFunds: Uint256){
    alloc_locals;
    ReentrancyGuard.start();
    assert_only_drip_transit();
    let (is_paused_) = Pausable.is_paused();
    let (can_liquidate_while_paused_) = can_liquidate_while_paused.read(_payer);
    let (is_drip_liquidation_) = is_equal(_type, 1);
    let (is_drip_expired_liquidation) = is_equal(_type, 2);

    if(is_paused_ == 1){
        with_attr error_message("Pausable: paused") {
            assert_not_zero(can_liquidate_while_paused_ * (is_drip_liquidation_ + is_drip_expired_liquidation)); 
        }
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }

    let type_ = _type*(1 - is_paused_) + 3 * is_paused_;

    let (drip_) = getDripOrRevert(_borrower);
    borrower_to_drip.write(_borrower, 0);

    let (borrowed_amount_, borrowed_amount_with_interests_,_) = calcDripAccruedInterest(drip_);
    let (amount_to_pool_, remaining_funds_, profit_, loss_) = calcClosePayments(_total_value, type_, borrowed_amount_, borrowed_amount_with_interests_);
    let (underlying_) = underlying_contract.read();
    let (underlying_balance_) = IERC20.balanceOf(underlying_, drip_);
    let (stack_) = SafeUint256.add(amount_to_pool_, remaining_funds_);
    let (is_surplus_) = uint256_lt(stack_, underlying_balance_);
    
    if (is_surplus_ == 1) {
        let (surplus_) = SafeUint256.sub_lt(underlying_balance_, stack_);
        IDrip.safeTransfer(drip_, underlying_, _to, surplus_);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        let (cover_) = SafeUint256.sub_le(stack_, underlying_balance_);
        IERC20.transferFrom(underlying_ ,_payer, drip_, cover_);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }

    let (pool_) = pool.read();
    IDrip.safeTransfer(drip_, underlying_, pool_, amount_to_pool_);
    IPool.repayDripDebt(pool_, borrowed_amount_, profit_, loss_);

    // transfer remaining funds to borrower [Liquidation case only]
    let (is_remaining_funds_) = uint256_lt(Uint256(0, 0), remaining_funds_);
    if (is_remaining_funds_ == 1) {
        IDrip.safeTransfer(drip_, underlying_, _borrower, remaining_funds_);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }   
    transfer_assets_to(drip_, _to);
    let (drip_factory_) = drip_factory.read();
    IDripFactory.returnDrip(drip_factory_, drip_);
    ReentrancyGuard.end();
    return (remaining_funds_,);
}

// @notice: Add Collateral 
// @param: _payer Collateral provider (felt)
// @param: _drip Drip to send Collateral (felt)
// @param: _token Token to send as Collateral (felt)
// @param: _amount Amount of token to send to as Collateral (Uint256)
@external
func addCollateral{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _payer: felt, _drip: felt, _token: felt, _amount: Uint256
) {
    alloc_locals;
    ReentrancyGuard.start();
    assert_only_drip_transit();
    Pausable.assert_not_paused();
    check_and_enable_token(_drip, _token);
    SafeERC20.transferFrom(_token, _payer, _drip, _amount);
    ReentrancyGuard.end();
    return ();
}

// @notice: Manage Debt 
// @param: _drip Drip to manage Debt (felt)
// @param: _amount of debt to increase / decrease (Uint256)
// @param: _increase 1 increase, else decrease (felt)
// @return: newBorrowedAmount New Borrowed Amount (Uint256)
@external
func manageDebt{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _drip: felt, _amount: Uint256, _increase: felt
) -> (newBorrowedAmount: Uint256) {
    alloc_locals;
    ReentrancyGuard.start();
    assert_only_drip_transit();
    Pausable.assert_not_paused();
    let (borrowed_amount_, cumulative_index_, current_cumulative_index_) = dripParameters(_drip);
    let (pool_) = pool.read();
    let (underlying_) = underlying_contract.read();
    if (_increase == 1) {
        let (new_borrowed_amount_) = SafeUint256.add(borrowed_amount_, _amount);
        let (cumulative_index_at_borrow_more_) = calc_new_cumulative_index(borrowed_amount_, _amount, current_cumulative_index_, cumulative_index_, 1);
        IPool.borrow(pool_, _amount, _drip);
        IDrip.updateParameters(_drip, new_borrowed_amount_, cumulative_index_at_borrow_more_);
        ReentrancyGuard.end();
        return (new_borrowed_amount_,);
    } else {
        let (step1_) = SafeUint256.mul(borrowed_amount_, current_cumulative_index_);
        let (step2_, _) = SafeUint256.div_rem(step1_, cumulative_index_);
        let (interest_accrued_) = SafeUint256.sub_le(step2_, borrowed_amount_);
        let (fee_interest_) = fee_interest.read();
        let (profit_precision_) = SafeUint256.mul(interest_accrued_, fee_interest_);
        let (profit_, _) = SafeUint256.div_rem(profit_precision_, Uint256(PRECISION, 0));
        let (interest_and_fees_) = SafeUint256.add(interest_accrued_, profit_);
        let (is_le_) = uint256_le(interest_and_fees_, _amount);
        if (is_le_ == 1){
            let (step1_) = SafeUint256.add(borrowed_amount_, interest_and_fees_);
            let (new_borrowed_amount_) = SafeUint256.sub_le(step1_, _amount);
            IDrip.safeTransfer(_drip, underlying_, pool_, _amount);
            let (to_repay_) = SafeUint256.sub_le(_amount, interest_and_fees_);
            IPool.repayDripDebt(pool_, to_repay_, profit_, Uint256(0, 0));
            let (new_cumulative_index_) = IPool.calcLinearCumulativeIndex(pool_);
            IDrip.updateParameters(_drip, new_borrowed_amount_, new_cumulative_index_);
            ReentrancyGuard.end();
            return(new_borrowed_amount_,);
        } else {
            let (step1_) = SafeUint256.mul(_amount, Uint256(PRECISION,0));
            let (step2_) = SafeUint256.add(Uint256(PRECISION,0), fee_interest_);
            let (amount_to_interest_,_) = SafeUint256.div_rem(step1_, step2_);
            let (amount_to_fees_) = SafeUint256.sub_le(_amount, amount_to_interest_);
            IDrip.safeTransfer(_drip, underlying_, pool_, _amount);
            IPool.repayDripDebt(pool_, Uint256(0,0), amount_to_fees_, Uint256(0, 0));
            let (new_cumulative_index_) = calc_new_cumulative_index(borrowed_amount_, amount_to_interest_, current_cumulative_index_, cumulative_index_, 0);
            IDrip.updateParameters(_drip, borrowed_amount_, new_cumulative_index_);
            ReentrancyGuard.end();
            return(borrowed_amount_,);
        }
    }
}

// @notice: Approve Drip
// @param: _borrower Borrower (felt)
// @param: _target Contract to give allowance (felt)
// @param: _token Token to approve (felt)
// @param: _amount Amount of token to approve (Uint256)
@external
func approveDrip{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrower: felt, _target: felt, _token: felt, _amount: Uint256
) {
    alloc_locals;
    ReentrancyGuard.start();
    assert_not_paused_or_emergency();
    let (caller_) = get_caller_address();
    let (adapter_to_contract_) = adapter_to_contract.read(caller_);
    let (drip_transit_) = drip_transit.read();
    let (is_drip_transit_) = is_equal(caller_, drip_transit_);
    if (is_drip_transit_ == 0) {
        let (adapter_to_contract_) = adapter_to_contract.read(caller_);
        let (is_target_) = is_equal(adapter_to_contract_,  _target);
        with_attr error_message("not allowed target") {
            assert_not_zero(_target * is_target_);
        }
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }
    let (token_mask_) = token_mask.read(_token);
    let (is_nul_)= uint256_eq(Uint256(0,0), token_mask_);
    with_attr error_message("not allowed token") {
        assert is_nul_ = 0;
    }
    let (drip_) = getDripOrRevert(_borrower);
    IDrip.approveToken(drip_, _token, _target, _amount);
    ReentrancyGuard.end();
    return ();
}

// @notice: Check Allowance and Execute order
// @param: _borrower Borrower (felt)
// @param: _to Contract to call (felt)
// @param: _selector Selector to use (felt)
// @param: _calldata_len Calldata length (felt)
// @param: _calldata Calldata (felt*)
// @return: retdata_len Returned data length (felt)
// @return: retdata Returned data (felt*)
@external
func executeOrder{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrower: felt, _to: felt, _selector: felt, _calldata_len: felt, _calldata: felt*
) -> (retdata_len: felt, retdata: felt*) {
    alloc_locals;
    ReentrancyGuard.start();
    assert_not_paused_or_emergency();
    let (caller_) = get_caller_address();
    let (adapter_to_contract_) = adapter_to_contract.read(caller_);
    let (is_target_) = is_equal(adapter_to_contract_, _to);
    with_attr error_message("not allowed target") {
        assert_not_zero(_to * is_target_);
    }
    let (drip_) = getDripOrRevert(_borrower);
    let (retdata_len: felt, retdata: felt*) = IDrip.execute(
        drip_, _to, _selector, _calldata_len, _calldata
    );
    ReentrancyGuard.end();
    return (retdata_len, retdata);
}

// @notice: Check Allowance and Enable token
// @param: _drip Drip to check and enable token (felt)
// @param: _token Token to enable (felt)
@external
func checkAndEnableToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt, _token: felt
) {
    ReentrancyGuard.start();
    assert_not_paused_or_emergency();
    assert_only_drip_transit_or_adapters();
    check_and_enable_token(_drip, _token);
    ReentrancyGuard.end();
    return ();
}

// @notice: Disable Token
// @param: _drip Drip to disable token (felt)
// @param: _token Token to disable (felt)
// @return: wasChanged 1 if token has been disabled (felt)
@external
func disableToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt,
    _token: felt
)->(wasChanged: felt) {
    alloc_locals;
    assert_not_paused_or_emergency();
    assert_only_drip_transit_or_adapters();
    ReentrancyGuard.start();
    let (was_changed_) = disable_token(_drip, _token);
    ReentrancyGuard.end();
    return (was_changed_,);
}

// @notice: transfer Drip Ownership 
// @param: _from Drip owner (felt)
// @param: _to User to transfer drip ownership (felt)
@external
func transferDripOwnership{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _from: felt, _to: felt
) {
    ReentrancyGuard.start();
    assert_only_drip_transit();
    assert_not_paused_or_emergency();
    let (drip_) = getDripOrRevert(_from);
    borrower_to_drip.write(_from, 0);
    safe_drip_set(_to, drip_);
    ReentrancyGuard.end();
    return ();
}


// Security Check

// @notice: Full Collateral Check
// @dev: Check Drip holding to make sure there is enough collateral, can potentially disble tokens
// @param: _drip Drip to check (felt)
@external
func fullCollateralCheck{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt
) {
    alloc_locals;
    ReentrancyGuard.start();
    assert_only_drip_transit_or_adapters();
    full_collateral_check(_drip);
    ReentrancyGuard.end();
    return ();
}

// @notice: Check And Optimize Enabled Tokens
// @dev: Check not too much tokens and remove some if necessary
// @param: _drip Drip to check and optimize (felt)
@external
func checkAndOptimizeEnabledTokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt
) {
    alloc_locals;
    assert_only_drip_transit_or_adapters();
    check_and_optimize_enabled_tokens(_drip);
    return ();
}


// Configurator

// @notice: Add Token
// @param: _token Token to add (felt)
@external
func addToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt) {
    assert_only_drip_configurator();
    add_token(_token);
    return ();
}

// @notice: Set Fees
// @param: _fee_interest Fee Interest (Uint256)
// @param: _fee_liquidation Fee Liquidation (Uint256)
// @param: _liquidation_discount Liquidation Discount (Uint256)
// @param: _fee_liquidation_expired Fee Liquidation for expired Drip (Uint256)
// @param: _liquidation_discount_expiredFee Liquidation Discount for expired Drip (Uint256)
@external
func setFees{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _fee_interest: Uint256,
    _fee_liquidation: Uint256,
    _liquidation_discount: Uint256,
    _fee_liquidation_expired: Uint256,
    _liquidation_discount_expired: Uint256
) {
    assert_only_drip_configurator();
    fee_interest.write(_fee_interest);
    fee_liqudidation.write(_fee_liquidation);
    liquidation_discount.write(_liquidation_discount);
    fee_liqudidation_expired.write(_fee_liquidation_expired);
    liquidation_discount_expired.write(_liquidation_discount_expired);
    return ();
}

// @notice: Set Liquidation threshold
// @param: _token Token to set Liquidation Threshold (felt)
// @param: _liquidation_threshold Liquidation Threshold value (Uint256)
@external
func setLiquidationThreshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _token: felt, _liquidation_threshold: Uint256
) {
    alloc_locals;
    assert_only_drip_configurator();
    let (token_mask_) = token_mask.read(_token);
    let (is_nul_) = uint256_eq(Uint256(0,0), token_mask_);
    with_attr error_message("token not allowed") {
        assert is_nul_ = 0;
    }
    liquidation_threshold_from_mask.write(token_mask_, _liquidation_threshold);
    return ();
}

// @notice: Set Forbid Mask
// @dev: A drip holding forbidden tokens have limited allowed interactions
// @param: _fobid_mask Forbidden Mask to Set (felt)
@external
func setForbidMask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _fobid_mask: Uint256
) {
    assert_only_drip_configurator();
    forbidden_token_mask.write(_fobid_mask);
    return ();
}

// @notice: Set Max Enabled Tokens
// @param: _new_max_enabled_tokens Max enabled tokens value (Uint256)
@external
func setMaxEnabledTokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _new_max_enabled_tokens: Uint256
) {
    assert_only_drip_configurator();
    max_allowed_enabled_tokens_length.write(_new_max_enabled_tokens);
    return ();
}

// @notice: Change Contract Allowance
// @dev: This function is use to add or remove allowed integrations
// @param: _adapter Adapter from Target Contract (felt)
// @param: _target Target Contract (felt)
@external
func changeContractAllowance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _adapter: felt, _target: felt
) {
    alloc_locals;
    assert_only_drip_configurator();
    if(_adapter == 0){
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    } else {
        adapter_to_contract.write(_adapter, _target);
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    }

    if(_target == 0){
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    } else {
        contract_to_adapter.write(_target, _adapter);
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    }
    return ();
}

// @notice: Upgrade Oracle Transit
// @param: _oracle_transit Oracle Transit (felt)
@external
func upgradeOracleTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_oracle_transit: felt) {
    assert_only_drip_configurator();
    oracle_transit.write(_oracle_transit);
    return ();
}

// @notice: Upgrade Drip Transit
// @param: _drip_transit Drip Transit (felt)
@external
func upgradeDripTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_drip_transit: felt) {
    assert_only_drip_configurator();
    drip_transit.write(_drip_transit);
    return ();
}

// @notice: Upgrade Drip Configurator
// @param: _drip_configurator Drip Configurator (felt)
@external
func setConfigurator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _drip_configurator: felt
) {
    assert_only_drip_configurator();
    drip_configurator.write(_drip_configurator);
    return ();
}

// @notice: Add Emergency Liquidator
// @param: _liquidator Liquidator (felt)
@external
func addEmergencyLiquidator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_liquidator: felt) {
    assert_only_drip_configurator();
    can_liquidate_while_paused.write(_liquidator, 1);
    return ();
}

// @notice: Remove Emergency Liquidator
// @param: _liquidator Liquidator (felt)
@external
func removeEmergencyLiquidator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_liquidator: felt) {
    assert_only_drip_configurator();
    can_liquidate_while_paused.write(_liquidator, 0);
    return ();
}

//
// Views
//

// Pause

// @notice: Is Paused
// @return: state 1 if pause, 0 else (felt)
@view
func isPaused{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (state : felt){
    let (is_paused_) = Pausable.is_paused();
    return(is_paused_,);
}

// Token

// @notice: Underlying Token
// @return: underlying Underlying Token(felt)
@view
func underlying{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    underlying: felt
) {
    let (underlying_) = underlying_contract.read();
    return (underlying_,);
}

// @notice: Allowed Token Length
// @return: tokenLength(felt)
@view
func allowedTokensLength{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    tokenLength: felt
) {
    let (allowed_token_length_) = allowed_tokens_length.read();
    return (allowed_token_length_,);
}

// @notice: Max Allowed Tokens Length per drip
// @return: maxAllowedTokensLength Max Allowed Tokens Length per drip(felt)
@view
func maxAllowedTokensLength{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    maxAllowedTokenLength: Uint256
) {
    let (max_allowed_enabled_tokens_length_) = max_allowed_enabled_tokens_length.read();
    return (max_allowed_enabled_tokens_length_,);
}

// @notice: Token Mask
// @dev: token to 2**index_token
// @return: tokenMask Token Mask(Uint256)
@view
func tokenMask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt) -> (tokenMask: Uint256) {
    let (token_mask_) = token_mask.read(_token);
    return(token_mask_,);
}

// @notice: Drip Enabled Tokens Mask
// @param: _drip Drip to check allowed tokens Mask (felt)
// @return: enabledTokens Drip Enabled Tokens Mask (Uint256)
@view
func enabledTokensMap{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_drip: felt) -> (enabledTokens: Uint256) {
    let (enabled_tokens_) = enabled_tokens.read(_drip);
    return(enabled_tokens_,);
}

// @notice: Forbidden Token Mask
// @return: forbiddenTokenMask Forbidden Token Mask (Uint256)
@view
func forbiddenTokenMask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (forbiddenTokenMask: Uint256) {
    let (forbidden_token_mask_) = forbidden_token_mask.read();
    return(forbidden_token_mask_,);
}

// @notice: Token by Mask
// @param: _token_mask Token Mask (Uint256)
// @return: token Token (felt)
@view
func tokenByMask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token_mask: Uint256) -> (token: felt) {
    let (token_) = token_from_mask.read(_token_mask);
    return(token_,);
}

// @notice: Token by Mask
// @param: _id Token ID (felt)
// @return: token Token (felt)
@view
func tokenById{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_id: felt) -> (token: felt) {
    let (token_mask_) = uint256_pow2(Uint256(_id,0));
    let (token_) = token_from_mask.read(token_mask_);
    return(token_,);
}

// @notice: Liquidation Threshold
// @param: _token Token to check Liquidation Threshold (felt)
// @return: LiquidationThreshold Liquidation Threshold (Uint256)
@view
func liquidationThreshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt) -> (LiquidationThreshold: Uint256) {
    alloc_locals;
    let (token_mask_) = token_mask.read(_token);
    let (is_zero_) = uint256_eq(token_mask_, Uint256(0,0));
    with_attr error_message("token not allowed") {
        is_zero_ = 0;
    }
    let (liquidation_threshold_) = liquidation_threshold_from_mask.read(token_mask_);
    return(liquidation_threshold_,);
}

// @notice: Liquidation Threshold By Mask
// @param: _token_mask Mask Token to check Liquidation Threshold (Uint256)
// @return: LiquidationThreshold Liquidation Threshold (Uint256)
@view
func liquidationThresholdByMask{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token_mask: Uint256) -> (LiquidationThreshold: Uint256) {
    let (liquidation_threshold_) = liquidation_threshold_from_mask.read(_token_mask);
    return(liquidation_threshold_,);
}

// @notice: Liquidation Threshold By ID
// @param: _id Token ID to check Liquidation Threshold (felt)
// @return: LiquidationThreshold Liquidation Threshold (Uint256)
@view
func liquidationThresholdById{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_id: felt) -> (LiquidationThreshold: Uint256) {
    let (token_mask_) = uint256_pow2(Uint256(_id,0));
    let (liquidation_threshold_) = liquidation_threshold_from_mask.read(token_mask_);
    return(liquidation_threshold_,);
}

// Contracts

// @notice: adapter to Contract
// @param: _adapter Adapter to check contract (felt)
// @return: contract Conract (felt)
@view
func adapterToContract{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_adapter: felt) -> (contract: felt) {
    let (contract_) = adapter_to_contract.read(_adapter);
    return(contract_,);
}

// @notice: Contract to Adapter
// @param: _contract Contract to check Adapter (felt)
// @return: adapter Adapter (felt)
@view
func contractToAdapter{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_contract: felt) -> (adapter: felt){
    alloc_locals;
    let (adapter_) = contract_to_adapter.read(_contract);
    return(adapter_,);
}

// Parameters

// @notice: Fee Interest
// @return: feeInterest Fee Interest (Uint256)
@view
func feeInterest{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (feeInterest: Uint256) {
    let (fee_interest_) = fee_interest.read();
    return(fee_interest_,);
}

// @notice: Fee Liquidation
// @return: feeLiquidation Fee Liquidation (Uint256)
@view
func feeLiquidation{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (feeLiquidation: Uint256) {
    let (fee_liqudidation_) = fee_liqudidation.read();
    return(fee_liqudidation_,);
}

// @notice: Fee Liquidation Expired
// @return: feeLiquidationExpired Fee Liquidation Expired (Uint256)
@view
func feeLiquidationExpired{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (feeLiquidationExpired: Uint256) {
    let (fee_liqudidation_expired_) = fee_liqudidation_expired.read();
    return(fee_liqudidation_expired_,);
}

// @notice: Liquidation Discount
// @return: liquidationDiscount Liquidation Discount (Uint256)
@view
func liquidationDiscount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (liquidationDiscount: Uint256) {
    let (liquidation_discount_) = liquidation_discount.read();
    return(liquidation_discount_,);
}

// @notice: Liquidation Discount Expired
// @return: liquidationDiscountExpired Liquidation Discount Expired (Uint256)
@view
func liquidationDiscountExpired{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (liquidationDiscountExpired: Uint256) {
    let (liquidation_discount_expired_) = liquidation_discount_expired.read();
    return(liquidation_discount_expired_,);
}

// @notice: Can Liquidate While Paused 
// @dev: Checks emergency liquidators
// @return: state 1 if allowed 0 else (felt)
@view
func canLiquidateWhilePaused{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_liquidator: felt) -> (state: felt) {
    let (can_liquidate_while_paused_) = can_liquidate_while_paused.read(_liquidator);
    return(can_liquidate_while_paused_,);
}

// Dependencies

// @notice: Get Pool
// @return: pool Pool (felt)
@view
func getPool{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (pool: felt) {
    let (pool_) = pool.read();
    return(pool_,);
}

// @notice: Drip Transit
// @return: dripTransit Drip Transit (felt)
@view
func dripTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (dripTransit: felt) {
    let (drip_transit_) = drip_transit.read();
    return(drip_transit_,);
}

// @notice: Drip Configurator
// @return: dripConfigurator Drip Configurator (felt)
@view
func dripConfigurator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (dripConfigurator: felt) {
    let (drip_configurator_) = drip_configurator.read();
    return(drip_configurator_,);
}

// @notice: Oracle Transit
// @return: oracleTransit Oracle Transit (felt)
@view
func oracleTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (oracleTransit: felt) {
    let (oracle_transit_) = oracle_transit.read();
    return(oracle_transit_,);
}

// Drip

// @notice: Get Drip
// @param: _borrower Borrower to check drip (felt)
// @return: drip Drip (felt)
@view
func getDrip{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrower: felt
) -> (drip: felt) {
    let (drip_) = borrower_to_drip.read(_borrower);
    return (drip_,);
}

// @notice: Get Drip Or Revert
// @dev: revert if borrower has no drip
// @param: _borrower Borrower to check drip (felt)
// @return: drip Drip (felt)
@view
func getDripOrRevert{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrower: felt
) -> (drip: felt) {
    let (drip_) = borrower_to_drip.read(_borrower);
    with_attr error_message("has not drip") {
        assert_not_zero(drip_);
    }
    return (drip_,);
}

// @notice: Drip Parameters
// @param: _drip Drip to check parameters (felt)
// @return: borrowedAmount Borrowed Amount (Uint256)
// @return: cumulativeIndex Drip Cumulative Index (Uint256)
// @return: currentCumulativeIndex Pool Cumulative Index (Uint256)
@view
func dripParameters{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _drip: felt
) -> (borrowedAmount: Uint256, cumulativeIndex: Uint256, currentCumulativeIndex: Uint256) {
    let (borrowed_amount_) = IDrip.borrowedAmount(_drip);
    let (cumulative_index_) = IDrip.cumulativeIndex(_drip);
    let (pool_) = pool.read();
    let (current_cumulative_index_) = IPool.calcLinearCumulativeIndex(pool_);
    return (borrowed_amount_, cumulative_index_, current_cumulative_index_,);
}

// @notice: Calcul Drip Accrued Interest
// @param: _drip Drip to calculate Accrued Interest (felt)
// @return: borrowedAmount Borrowed Amount (Uint256)
// @return: borrowedAmountWithInterest Borrowed Amount With Interest (Uint256)
// @return: borrowedAmountWithInterestAndFees Borrowed Amount With Interest And Fees (Uint256)
@view
func calcDripAccruedInterest{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _drip: felt
) -> (borrowedAmount: Uint256, borrowedAmountWithInterest: Uint256, borrowedAmountWithInterestAndFees: Uint256) {
    alloc_locals;
    let (borrowed_amount_, cumulative_index_, current_cumulative_index_) = dripParameters(_drip);
    let (step1_) = SafeUint256.mul(borrowed_amount_, current_cumulative_index_);
    let (borrowed_amount_with_interests_, _) = SafeUint256.div_rem(
        step1_, cumulative_index_
    );
    let (fee_interest_) = fee_interest.read();
    let (interest_) = SafeUint256.sub_le(borrowed_amount_with_interests_, borrowed_amount_);
    let (fees_precision_) = SafeUint256.mul(interest_, fee_interest_);
    let (fees_,_) = SafeUint256.div_rem(fees_precision_, Uint256(PRECISION,0));
    let (borrowed_amount_with_interests_and_fees_) = SafeUint256.add(borrowed_amount_with_interests_, fees_);
    return (borrowed_amount_, borrowed_amount_with_interests_, borrowed_amount_with_interests_and_fees_,);
}


// @notice: Calcul Close Payments
// @param: _total_value Total Value (Uint256)
// @param _type 0 and other: ordinary closure type 1: liquidation, 2: drip expired liquidation, 3: pause liquidation (felt)
// @param: _borrowed_amount Borrowed Amount (Uint256)
// @param: _borrowed_amount_with_interests Borrowed Amount With Interest (Uint256)
// @return: amountToPool Amount to send to the Pool (Uint256)
// @return: remainingFunds Remaining funds for the borrower, liquidation case only (Uint256)
// @return: profit Pool Profit or fees taken byt the pool (Uint256)
// @return: loss Pool Loss borrowed amount plus interest less total funds, liquidation case only (Uint256)
@view
func calcClosePayments{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _total_value: Uint256,
    _type: felt,
    _borrowed_amount: Uint256,
    _borrowed_amount_with_interests: Uint256
) -> (amountToPool: Uint256, remainingFunds: Uint256, profit: Uint256, loss: Uint256) {
    alloc_locals;
    let (fee_interest_) = fee_interest.read();
    let (step1_) = SafeUint256.sub_le(_borrowed_amount_with_interests, _borrowed_amount);
    let (step2_) = SafeUint256.mul(step1_, fee_interest_);
    let (step3_, _) = SafeUint256.div_rem(step2_, Uint256(PRECISION, 0));
    let (amount_to_pool_) = SafeUint256.add(step3_, _borrowed_amount_with_interests);
    
    let (is_drip_liquidated_) = is_equal(_type, 1);
    let (is_drip_expired_liquidated_) = is_equal(_type, 2);
    let (is_pause_liquidation_) = is_equal(_type, 3);

    if (is_drip_liquidated_ + is_drip_expired_liquidated_ + is_pause_liquidation_ == 1) {

        // liquidation
        let (liquidation_discount_) = liquidation_discount.read();
        let (fee_liqudidation_) = fee_liqudidation.read();
        let (step1_) = SafeUint256.mul(_total_value, liquidation_discount_);
        let (total_funds_liquidation_, _) = SafeUint256.div_rem(step1_, Uint256(PRECISION, 0));
        let (step1_) = SafeUint256.mul(_total_value, fee_liqudidation_);
        let (step2_,_) = SafeUint256.div_rem(step1_, Uint256(PRECISION, 0));
        let (new_amount_to_pool_liquidation_) = SafeUint256.add(step2_, amount_to_pool_);

        // liquidation expired
        let (liquidation_discount_expired_) = liquidation_discount_expired.read();
        let (fee_liqudidation_expired_) = fee_liqudidation_expired.read();
        let (step1_) = SafeUint256.mul(_total_value, liquidation_discount_expired_);
        let (total_funds_liquidation_expired_, _) = SafeUint256.div_rem(step1_, Uint256(PRECISION, 0));
        let (step1_) = SafeUint256.mul(_total_value, fee_liqudidation_expired_);
        let (step2_,_) = SafeUint256.div_rem(step1_, Uint256(PRECISION, 0));
        let (new_amount_to_pool_liquidation_expired_) = SafeUint256.add(step2_, amount_to_pool_);

        // liquidation paused
        let (step1_) = SafeUint256.mul(_total_value, fee_liqudidation_);
        let (step2_,_) = SafeUint256.div_rem(step1_, Uint256(PRECISION, 0));
        let (new_amount_to_pool_liquidation_paused_) = SafeUint256.add(step2_, amount_to_pool_);
    

        let (new_amount_to_pool1_) = SafeUint256.mul(new_amount_to_pool_liquidation_, Uint256(is_drip_liquidated_,0));
        let (new_amount_to_pool2_) = SafeUint256.mul(new_amount_to_pool_liquidation_expired_, Uint256(is_drip_expired_liquidated_,0));
        let (new_amount_to_pool3_) = SafeUint256.mul(new_amount_to_pool_liquidation_paused_, Uint256(is_pause_liquidation_,0));
        let (step1_) = SafeUint256.add(new_amount_to_pool1_, new_amount_to_pool2_);
        let (new_amount_to_pool_) = SafeUint256.add(step1_, new_amount_to_pool3_);

        let (new_total_funds1_) = SafeUint256.mul(total_funds_liquidation_, Uint256(is_drip_liquidated_,0));
        let (new_total_funds2_) = SafeUint256.mul(total_funds_liquidation_expired_, Uint256(is_drip_expired_liquidated_,0));
        let (new_total_funds3_) = SafeUint256.mul(_total_value, Uint256(is_pause_liquidation_,0));
        let (step1_) = SafeUint256.add(new_total_funds1_, new_total_funds2_);
        let (new_total_funds_) = SafeUint256.add(step1_, new_total_funds3_);
        
        let (is_lt_) = uint256_le(new_amount_to_pool_, new_total_funds_);
        if (is_lt_ == 1) {
            let (remaining_funds_) = SafeUint256.sub_le(new_total_funds_, new_amount_to_pool_);
            let (profit_) = SafeUint256.sub_le(new_amount_to_pool_, _borrowed_amount_with_interests);
            return (new_amount_to_pool_, remaining_funds_, profit_, Uint256(0,0));
        } else {
            let (is_le_) = uint256_le(_borrowed_amount_with_interests, new_total_funds_);
            if (is_le_ == 1) {
                let (profit_) = SafeUint256.sub_le(new_total_funds_, _borrowed_amount_with_interests);
                return (new_total_funds_, Uint256(0,0), profit_, Uint256(0,0));
            } else {
                let (loss_) = SafeUint256.sub_lt(_borrowed_amount_with_interests, new_total_funds_);
                return (new_total_funds_, Uint256(0,0), Uint256(0,0), loss_);
            }
        }
    } else {
        let (profit_) = SafeUint256.sub_lt(amount_to_pool_, _borrowed_amount_with_interests);
        return (amount_to_pool_, Uint256(0,0), profit_, Uint256(0,0));
    }
}


//
// Internals
//

// @notice: full_collateral_check
// @param: _drip Drip to Check (Uint256)
func full_collateral_check{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(_drip: felt) {
    alloc_locals;
    let (oracle_transit_) = oracle_transit.read();
    let (enabled_tokens_) = enabled_tokens.read(_drip);
    let (underlying_) = underlying_contract.read();
    let (_,_, borrowed_amount_with_interests_and_fees_) = calcDripAccruedInterest(_drip);
    let (borrowed_amount_with_interests_and_fees_precision_) = SafeUint256.mul(borrowed_amount_with_interests_and_fees_, Uint256(PRECISION,0));
    let (borrowed_amount_with_interests_and_fees_usd_) = IOracleTransit.convertToUSD(oracle_transit_, borrowed_amount_with_interests_and_fees_precision_, underlying_);
    let (max_index_) = get_max_index(enabled_tokens_);
    recursive_calcul_value(oracle_transit_, _drip, enabled_tokens_, Uint256(0,0), borrowed_amount_with_interests_and_fees_usd_, Uint256(0,0), max_index_);
    return ();
}

// @notice: recursive_calcul_value
// @dev: Loop Drip Holdings and check if enough collateral
// @param: _oracle_transit Oracle Transit (felt)
// @param: _drip Drip (felt)
// @param: _enabled_tokens Enabled Tokens for Drip (Uint256)
// @param; _cumulative_twv_usd Cumulative Total Weighted Value (Uint256)
// @param; _borrowed_amount_with_interests Borrowed Amount with Interests (Uint256)
// @param; _index Token Index (Uint256)
// @param; _max_index Max Token Index (Uint256)
func recursive_calcul_value{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
        _oracle_transit: felt,
        _drip: felt,
        _enabled_tokens: Uint256,
        _cumulative_twv_usd: Uint256,
        _borrowed_amount_with_interests: Uint256,
        _index: Uint256,
        _max_index: Uint256) {
    alloc_locals;
    let (is_le_) = uint256_le(_index, _max_index);
    with_attr error_message("not enough collateral") {
        assert is_le_ = 1;
    }
    let (new_index_) = SafeUint256.add(_index, Uint256(1,0));
    let (token_mask_) = uint256_pow2(_index);
    let (low_) = bitwise_and(_enabled_tokens.low, token_mask_.low);
    let (high_) = bitwise_and(_enabled_tokens.high, token_mask_.high);
    let (is_lt_) = uint256_lt(Uint256(0, 0), Uint256(low_, high_));
    if (is_lt_ == 1) {
        let (token_) =  tokenByMask(token_mask_);
        let (balance_) = IERC20.balanceOf(token_, _drip);
        let (has_token_) = uint256_lt(Uint256(1, 0), balance_);
        if (has_token_ == 1) {
            let (value_) = IOracleTransit.convertToUSD(_oracle_transit, balance_, token_);
            let (lt_) = liquidationThreshold(token_);
            let (lt_value_) = SafeUint256.mul(value_, lt_);
            let (new_cumulative_twv_usd_) = SafeUint256.add(_cumulative_twv_usd, lt_value_);
            let (is_le_) = uint256_le(_borrowed_amount_with_interests, new_cumulative_twv_usd_);
            if(is_le_ == 1){
                let (total_tokens_enabled_) = calc_enabled_tokens(_enabled_tokens,  Uint256(0,0));
                let (max_allowed_enabled_tokens_length_) = max_allowed_enabled_tokens_length.read();
                let (is_lt_) = uint256_lt(max_allowed_enabled_tokens_length_, total_tokens_enabled_);
                if(is_lt_ == 1){
                    let (new_max_index_) = SafeUint256.sub_le(_max_index, _index);
                    optimize_enabled_tokens(_drip, _enabled_tokens, total_tokens_enabled_, Uint256(1,0), _max_index);
                    return();
                } else {
                    enabled_tokens.write(_drip, _enabled_tokens);
                    return();
                }
            } else {
                return recursive_calcul_value(_oracle_transit, _drip, _enabled_tokens, new_cumulative_twv_usd_, _borrowed_amount_with_interests, new_index_, _max_index);
            }
        } else {
            let (low_) = bitwise_xor(_enabled_tokens.low, token_mask_.low);
            let (high_) = bitwise_xor(_enabled_tokens.high, token_mask_.high);
            return recursive_calcul_value(_oracle_transit, _drip, Uint256(low_, high_), _cumulative_twv_usd, _borrowed_amount_with_interests, new_index_, _max_index);
            }
    } else {
        return recursive_calcul_value(_oracle_transit, _drip, _enabled_tokens, _cumulative_twv_usd, _borrowed_amount_with_interests, new_index_, _max_index);
    }
}

// @notice: transfer_assets_to
// @param: _drip Drip to send assets from (felt)
// @param: _to Assets receiver (felt)
func transfer_assets_to{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt, _to: felt
) {
    alloc_locals;
    with_attr error_message("can't send to the zero address") {
        assert_not_zero(_to);
    }
    let (enabled_tokens_) = enabled_tokens.read(_drip);
    recursive_transfer_token(1, _drip, _to, enabled_tokens_);
    return ();
}

// @notice: recursive_transfer_token
// @dev: Loop Drip Holdings and send assets to the receiver
// @param: _index Index token (felt)
// @param: _drip Drip to send assets from (felt)
// @param: _to Assets receiver (felt)
// @param: _enabled_tokens Enabled Tokens for Drip (Uint256)
func recursive_transfer_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
        _index: felt,
        _drip: felt,
        _to: felt,
        _enabled_tokens: Uint256) {
    alloc_locals;
    let (token_mask_) = uint256_pow2(Uint256(_index, 0));
    let (is_le_) = uint256_le(token_mask_, _enabled_tokens);
    if (is_le_ == 0) {
        return ();
    }
    let (low_) = bitwise_and(_enabled_tokens.low, token_mask_.low);
    let (high_) = bitwise_and(_enabled_tokens.high, token_mask_.high);
    let (is_bt_) = uint256_lt(Uint256(0, 0), Uint256(low_, high_));
    if (is_bt_ == 1) {
        let (token_) = token_from_mask.read(token_mask_);
        let (balance_) = IERC20.balanceOf(token_, _drip);
        let (has_token_) = uint256_lt(Uint256(1, 0), balance_);
        if (has_token_ == 1) {
            IDrip.safeTransfer(_drip, token_, _to, balance_);
            tempvar syscall_ptr = syscall_ptr;
            tempvar range_check_ptr = range_check_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
        } else {
            tempvar syscall_ptr = syscall_ptr;
            tempvar range_check_ptr = range_check_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
        }
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
    }
    return recursive_transfer_token(
        _index + 1, _drip, _to, _enabled_tokens
    );
}

// @notice: check_and_enable_token
// @dev: Check if allowed token and add enable it for Drip
// @param: _drip Drip to enable token (felt)
// @param: _token Token to check and enable (felt)
func check_and_enable_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt, _token: felt
) {
    alloc_locals;
    let (token_mask_) = token_mask.read(_token);
    let (is_nul1_) = uint256_eq(token_mask_, Uint256(0,0));
    with_attr error_message("not allowed token") {
        assert is_nul1_ = 0;
    }
    let (forbidden_token_mask_) = forbidden_token_mask.read();
    let (low_) = bitwise_and(forbidden_token_mask_.low, token_mask_.low);
    let (high_) = bitwise_and(forbidden_token_mask_.high, token_mask_.high);
    let (is_nul2_) = uint256_eq(Uint256(0, 0), Uint256(low_, high_));
    with_attr error_message("token forbidden") {
        assert_not_zero(is_nul2_);
    }

    let (enabled_tokens_) = enabled_tokens.read(_drip);
    let (low_) = bitwise_and(enabled_tokens_.low, token_mask_.low);
    let (high_) = bitwise_and(enabled_tokens_.high, token_mask_.high);
    let (is_eq_) = uint256_eq(Uint256(0, 0), Uint256(low_, high_));
    if (is_eq_ == 1) {
        let (low_) = bitwise_or(enabled_tokens_.low, token_mask_.low);
        let (high_) = bitwise_or(enabled_tokens_.high, token_mask_.high);
        enabled_tokens.write(_drip, Uint256(low_, high_));
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar bitwise_ptr = bitwise_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar range_check_ptr = range_check_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar bitwise_ptr = bitwise_ptr;
    }
    return ();
}

// @notice: disable_token
// @param: _drip Drip to disable token (felt)
// @param: _token Token to disable (felt)
func disable_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt, _token: felt
)-> (was_changed: felt) {
    let (token_mask_) = token_mask.read(_token);
    let (enabled_tokens_) = enabled_tokens.read(_drip);
    let (low_) = bitwise_and(enabled_tokens_.low, token_mask_.low);
    let (high_) = bitwise_and(enabled_tokens_.high, token_mask_.high);
    let (is_bt_) = uint256_lt(Uint256(0, 0), Uint256(low_, high_));
    if (is_bt_ == 1) {
        let (low_) = bitwise_xor(enabled_tokens_.low, token_mask_.low);
        let (high_) = bitwise_xor(enabled_tokens_.high, token_mask_.high);
        enabled_tokens.write(_drip, Uint256(low_, high_));
        return (1,);
    } 
    return (0,);
}

// @notice: safe_drip_set
// @dev: check is borrower does not hold a Drip
// @param: _borrower Borrower (felt)
// @param: _drip Drip to set (felt)
func safe_drip_set{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    _borrower: felt, _drip: felt
) {
    let (drip_) = borrower_to_drip.read(_borrower);
    let (has_not_drip_) = is_equal(0, drip_);
    with_attr error_message("zero address or user already has a drip") {
        assert_not_zero(_borrower * has_not_drip_);
    }
    borrower_to_drip.write(_borrower, _drip);
    return ();
}


// @notice: add_token
// @param: _token Token to add (felt)
func add_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt) {
    alloc_locals;
    let (token_mask_) = token_mask.read(_token);
    let (is_lt_) = uint256_lt(Uint256(0, 0), token_mask_);
    with_attr error_message("token already added") {
        assert is_lt_ = 0;
    }

    let (allowed_token_length_) = allowed_tokens_length.read();
    let (is_le_) = uint256_le(Uint256(256, 0), Uint256(allowed_token_length_, 0));
    with_attr error_message("too much tokens") {
        assert is_le_ = 0;
    }

    let (token_mask_) = uint256_pow2(Uint256(allowed_token_length_, 0));
    token_mask.write(_token, token_mask_);
    token_from_mask.write(token_mask_, _token);
    allowed_tokens_length.write(allowed_token_length_ + 1);
    return ();
}

// @notice: calc_new_cumulative_index
// @dev: adapt the drip cumulative index if borrowed amount change
// @param: _borrowed_amount Borrowed Amount (Uint256)
// @param; _delta Delta is the absolute value of the difference between current and new borrowed amount (Uint256)
// @param: _current_cumulative_index Pool Cumulative Index (Uint256)
// @param: _drip_cumulative_index Drip Cumulative Index (Uint256)
// @param: is_increase Increase Debt if 1, Decrease Debt else (felt)
// @return: new_cumulative_index New Cumulative Index (Uint256)
func calc_new_cumulative_index{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_borrowed_amount: Uint256, _delta: Uint256, _current_cumulative_index: Uint256, _drip_cumulative_index: Uint256, is_increase: felt) -> (new_cumulative_index: Uint256) {
    alloc_locals;
    if(is_increase == 1){

        // 1 index * new borrow
        let (new_borrowed_amount_) = SafeUint256.add(_borrowed_amount, _delta);
        let (step1_) = SafeUint256.mul(_current_cumulative_index, new_borrowed_amount_);
        let (step2_) = SafeUint256.mul(step1_, Uint256(PRECISION,0));

        // 2 (index * borrow) / drip index
        let (step3_) = SafeUint256.mul(_current_cumulative_index, _borrowed_amount);
        let (step4_) = SafeUint256.mul(step3_, Uint256(PRECISION,0));
        let (step5_,_) = SafeUint256.div_rem(step4_, _drip_cumulative_index);


        // 3 delta
        let (step6_) = SafeUint256.mul(Uint256(PRECISION,0), _delta);

        // 1 / (2 + 3)
        let (step7_) = SafeUint256.add(step5_, step6_);
        let (cumulative_index_at_borrow_more_, _) = SafeUint256.div_rem(step2_, step7_);
        return(cumulative_index_at_borrow_more_,);
    } else {

        // 1 index * drip index
        let (step1_) = SafeUint256.mul(_current_cumulative_index, _drip_cumulative_index);
        let (step2_) = SafeUint256.mul(step1_, Uint256(PRECISION,0));

        // 2 index
        let (step3_) = SafeUint256.mul(_current_cumulative_index, Uint256(PRECISION,0));

        // 3 delta*drip index / borrwed amount
        let (step4_) = SafeUint256.mul(_drip_cumulative_index, Uint256(PRECISION,0));
        let (step5_) = SafeUint256.mul(step4_, _delta);
        let (step6_,_) = SafeUint256.div_rem(step5_, _borrowed_amount);

        // 1 / (2 - 3)
        let (step7_) = SafeUint256.sub_le(step3_, step6_);
        let (new_cumulative_index_,_) = SafeUint256.div_rem(step2_, step7_);
        return(new_cumulative_index_,);
    }
}

// @notice: check_and_optimize_enabled_tokens
// @param: _drip Drip to Check and Optimize (felt)
func check_and_optimize_enabled_tokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt) {
    alloc_locals;
    let (enabled_tokens_) = enabled_tokens.read(_drip);
    let (total_tokens_enabled_) = calc_enabled_tokens(enabled_tokens_, Uint256(0,0));
    let (max_allowed_enabled_tokens_length_) = max_allowed_enabled_tokens_length.read();
    let (is_lt_) = uint256_lt(max_allowed_enabled_tokens_length_, total_tokens_enabled_);

    if(is_lt_ == 1){
        let (max_index_) = get_max_index(enabled_tokens_);
        optimize_enabled_tokens(_drip, enabled_tokens_, total_tokens_enabled_, Uint256(0,0), max_index_);
        return ();
    }
    return ();
}

// @notice: optimize_enabled_tokens
// @param: _drip Drip to Optimize (felt)
// @param: _enabled_tokens Drip Enabled Tokens (Uint256)
// @param: _total_tokens_enabled Drip Total Tokens Enabled (Uint256)
// @param: _index Token Index (Uint256)
// @param: _max_index Drip Max Token Index (Uint256)
func optimize_enabled_tokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _drip: felt,
    _enabled_tokens: Uint256,
    _total_tokens_enabled: Uint256,
    _index: Uint256,
    _max_index: Uint256) {
    alloc_locals;
    let (token_mask_) = uint256_pow2(_index);
    let (new_index_) = SafeUint256.add(_index, Uint256(1,0));
    let (low_) = bitwise_and(token_mask_.low, _enabled_tokens.low);
    let (high_) = bitwise_and(token_mask_.high, _enabled_tokens.high);
    let (is_eq_) = uint256_eq(Uint256(0, 0), Uint256(low_, high_));
    let (is_index_max_) = uint256_eq(_max_index, _index);
    if(is_eq_ == 1){
        with_attr error_message("Too many enabled tokens") {
            assert is_index_max_ = 0;
        }
        return optimize_enabled_tokens(_drip, _enabled_tokens, _total_tokens_enabled, new_index_, _max_index);  
    } else {
        let (token_) = tokenByMask(token_mask_);
        let (balance_) = IERC20.balanceOf(token_, _drip);
        let (is_le_) = uint256_le(Uint256(1,0), balance_);
        if(is_le_ == 0){
            let (low_) = bitwise_xor(_enabled_tokens.low, token_mask_.low);
            let (high_) = bitwise_xor(_enabled_tokens.high, token_mask_.high);
            let (new_total_tokens_enabled_) = SafeUint256.sub_le(_total_tokens_enabled, Uint256(1,0));
            let (max_allowed_enabled_tokens_length_) = max_allowed_enabled_tokens_length.read();
            let (is_le_) = uint256_le(new_total_tokens_enabled_, max_allowed_enabled_tokens_length_);
            if(is_le_ == 1){
                enabled_tokens.write(_drip, Uint256(low_, high_));
                return();
            } else {
                 with_attr error_message("Too many enabled tokens") {
                    assert is_index_max_ = 0;
                }
                return optimize_enabled_tokens(_drip, Uint256(low_, high_), new_total_tokens_enabled_, new_index_, _max_index);  
            }
        } else {
            with_attr error_message("Too many enabled tokens") {
                assert is_index_max_ = 0;
            }
            return optimize_enabled_tokens(_drip, _enabled_tokens, _total_tokens_enabled, new_index_, _max_index);  
        }
    }
}

// @notice: get_max_index
// @param: _mask Mask of allowed Tokens (Uint256)
// @return: max_index_ Max Drip Index (Uint256)
@view
func get_max_index{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(_mask: Uint256) -> (max_index: Uint256) {
    alloc_locals;
    let (is_one_) = uint256_eq(_mask, Uint256(1,0));
    if(is_one_ == 1){
        return(Uint256(0,0),);
    }
    let (max_index_) =  recursive_search_max_index(Uint256(255,0), _mask);
    return (max_index_,);
}

// @notice: recursive_search_max_index
// @param: _cumulative_index_ Cumulative Token Index (Uint256)
// @param: max_index Max Index (Uint256)
// @return: max_index Max Drip Index (Uint256)
func recursive_search_max_index{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(_cumulative_index_: Uint256, _mask: Uint256) -> (max_index: Uint256) {
    alloc_locals;
    let (pow2_) = uint256_pow2(_cumulative_index_);
    let (low_) = bitwise_and(pow2_.low, _mask.low);
    let (high_) = bitwise_and(pow2_.high, _mask.high);
    let (is_lt_) = uint256_lt(Uint256(0, 0), Uint256(low_, high_));
    if(is_lt_ == 1){
        return(_cumulative_index_,);
    } else {
        let (new_cumulative_index_) = SafeUint256.sub_le(_cumulative_index_, Uint256(1,0));
        return recursive_search_max_index(new_cumulative_index_, _mask);
    }
}

// @notice: calc_enabled_tokens
// @param: _enabled_tokens Enabled Tokens Mask (Uint256)
// @param: _cum_total_tokens_enabled Cumulative Total Tokens Enbaled (Uint256)
// @return: total_tokens_enabled Total Tokens Enabled (Uint256)
@view
func calc_enabled_tokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(
    _enabled_tokens: Uint256, _cum_total_tokens_enabled: Uint256) -> (total_tokens_enabled: Uint256){
    alloc_locals;
    let (is_lt_) = uint256_lt(Uint256(0,0), _enabled_tokens);
    if(is_lt_ == 1){
        let (is_enabled_) = bitwise_and(1, _enabled_tokens.low);
        let (cum_total_tokens_enabled_) = SafeUint256.add(_cum_total_tokens_enabled, Uint256(is_enabled_, 0));
        let (enabled_tokens_,_) = SafeUint256.div_rem(_enabled_tokens,Uint256(2,0));
        return calc_enabled_tokens(enabled_tokens_, cum_total_tokens_enabled_);
    } else {
        return(_cum_total_tokens_enabled,);
    }
}

// @notice: is_equal
// @param: _a first arg (felt)
// @param: _b second arg (felt)
// @return: state 1 if equal, 0 else (felt)
func is_equal{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(a: felt, b: felt) -> (state: felt) {
    if (a == b){
        return(1,);
    } else {
        return(0,);
    }
}
