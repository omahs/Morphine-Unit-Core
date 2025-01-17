%lang starknet

from starkware.starknet.common.syscalls import (
    get_block_timestamp,
    get_caller_address,
    call_contract,
)

from starkware.cairo.common.uint256 import ALL_ONES, Uint256, uint256_eq, uint256_lt, uint256_le
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.bitwise import bitwise_and, bitwise_xor, bitwise_or
from starkware.cairo.common.math import assert_not_zero
from openzeppelin.token.erc20.IERC20 import IERC20
from openzeppelin.security.safemath.library import SafeUint256

from morphine.utils.RegisteryAccess import RegisteryAccess
from morphine.utils.safeerc20 import SafeERC20
from morphine.utils.various import DEFAULT_FEE_INTEREST, DEFAULT_FEE_LIQUIDATION, DEFAULT_LIQUIDATION_PREMIUM, DEFAULT_FEE_LIQUIDATION_EXPIRED_PREMIUM, DEFAULT_FEE_LIQUIDATION_EXPIRED, PRECISION, DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER

from morphine.interfaces.IRegistery import IRegistery
from morphine.interfaces.IDripManager import IDripManager
from morphine.interfaces.IDripTransit import IDripTransit
from morphine.interfaces.IDripConfigurator import IDripConfigurator, AllowedToken
from morphine.interfaces.IAdapter import IAdapter
from morphine.interfaces.IPool import IPool
from morphine.interfaces.IOracleTransit import IOracleTransit

/// @title Drip Configurator
/// @author 0xSacha
/// @dev Contract Used to Manage Drip Infrastructure parameters
/// @custom:experimental This is an experimental contract.

// Events

@event 
func maxEnabledTokensSet(max_enabled_tokens: Uint256){
}

@event 
func TokenAllowed(token: felt){
}

@event 
func TokenForbidden(token: felt){
}

@event 
func ContractAllowed(contract: felt, adapter: felt){
}

@event 
func ContractForbidden(contract: felt){
}

@event 
func LimitsUpdated(minimum_borrowed_amount: Uint256, maximum_borrowed_amount: Uint256){
}

@event 
func LimitPerBlockUpdated(limit_per_block: Uint256){
}

@event 
func FastCheckFeesUpdated(chi_threshold: Uint256, hf_check_interval: Uint256){
}

@event 
func FeesUpdated(fee_interest: Uint256, fee_liquidation: Uint256, liquidation_premium: Uint256, fee_liquidation_expired: Uint256, liquidation_premium_expired: Uint256){
}

@event 
func OracleTransitUpgraded(oracle: felt){
}

@event 
func DripTransitUpgraded(drip_transit: felt){
}

@event 
func DripConfiguratorUpgraded(drip_configurator: felt){
}

@event 
func TokenLiquidationThresholdUpdated(token: felt, liquidation_threshold: Uint256){
}

@event 
func IncreaseDebtForbiddenStateChanged(state: felt){
}

@event 
func ExpirationDateUpdated(expiration_date: felt){
}

@event 
func EmergencyLiquidatorAdded(liquidator: felt){
}

@event 
func EmergencyLiquidatorRemoved(liquidator: felt){
}


// Storage

@storage_var
func drip_manager() -> (address : felt) {
}

@storage_var
func liquidation_threshold(token_address : felt) -> (res: felt) {
}

@storage_var
func id_to_allowed_contract(id : felt) -> (contract: felt) {
}

@storage_var
func allowed_contract_to_id(contract : felt) -> (id: felt) {
}

@storage_var
func allowed_contract_length() -> (length: felt) {
}

@storage_var
func is_allowed_contract(contract: felt) -> (is_allowed_contract : felt){
}

@storage_var
func underlying() -> (underlying : felt){
}




//Constructor

// @notice: Constructor will be called when the contract is deployed
// @param drip_manager: Address of the DripManager contract
// @param drip_transit: Address of the DripTransit contract
// @param _minimum_borrowed_amount: Minimum amount of tokens that can be borrowed (Uint256)
// @param _maximum_borrowed_amount: Maximum amount of tokens that can be borrowed (Uint256)
// @param _allowed_tokens: Array of allowed tokens
// @param _allowed_tokens_len: Length of the array of allowed tokens (AllowedToken*)
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        _drip_manager: felt,
        _drip_transit: felt,
        _minimum_borrowed_amount: Uint256, // minimal amount for drip 
        _maximum_borrowed_amount: Uint256, // maximum amount for drip 
        _allowed_tokens_len: felt,
        _allowed_tokens: AllowedToken*) {
    alloc_locals;
    drip_manager.write(_drip_manager);
    let (pool_) = IDripManager.getPool(_drip_manager);
    let (underlying_) = IPool.asset(pool_);
    underlying.write(underlying_);
    let (registery_) = IPool.getRegistery(pool_);
    RegisteryAccess.initializer(registery_);

    set_fees(Uint256(DEFAULT_FEE_INTEREST,0),Uint256(DEFAULT_FEE_LIQUIDATION,0), Uint256(PRECISION - DEFAULT_LIQUIDATION_PREMIUM,0), Uint256(DEFAULT_FEE_LIQUIDATION_EXPIRED,0), Uint256(PRECISION - DEFAULT_FEE_LIQUIDATION_EXPIRED_PREMIUM,0));
    allow_token_list(_allowed_tokens_len, _allowed_tokens);
    let (oracle_transit_) = IDripManager.oracleTransit(_drip_manager);
    IDripManager.upgradeDripTransit(_drip_manager, _drip_transit);
    DripTransitUpgraded.emit(_drip_transit);
    OracleTransitUpgraded.emit(oracle_transit_);
    let (limit_per_block_ ) = SafeUint256.mul(_maximum_borrowed_amount, Uint256(DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER,0));
    set_limit_per_block(limit_per_block_);
    set_limits(_minimum_borrowed_amount, _maximum_borrowed_amount);
    return();
}


// TOKEN MANAGEMENT

// @notice: Set the maximum number of tokens that can be allowed
// @param _new_max_enabled_tokens: Maximum number of tokens that can be allowed (Uint256)
// @dev: Should not execeed 256
@external
func setMaxEnabledTokens{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_new_max_enabled_tokens: Uint256){
    RegisteryAccess.assert_only_owner();
    let (is_allowed_) = uint256_le(_new_max_enabled_tokens, Uint256(256,0));
    with_attr error_message("max limit reached"){
        assert is_allowed_ = 1;
    }
    let (drip_manager_) = drip_manager.read();
    IDripManager.setMaxEnabledTokens(drip_manager_, _new_max_enabled_tokens);
    maxEnabledTokensSet.emit(_new_max_enabled_tokens);
    return();
}

// @notice: Allow a token to be used 
// @param token_address: Address of the token to be allowed (felt)
@external
func addToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt, _liquidation_threshold: Uint256){
    RegisteryAccess.assert_only_owner();
    add_token(_token);
    set_liquidation_threshold(_token, _liquidation_threshold);
    return();
}

// @notice: Set the liquidation threshold for a token
// @param token_address: Address of the token (felt)
// @param _liquidation_threshold: Liquidation threshold for the token (Uint256)
@external
func setLiquidationThreshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt, _liquidation_threshold: Uint256){
    RegisteryAccess.assert_only_owner();
    set_liquidation_threshold(_token, _liquidation_threshold);
    return();
}

// @notice: Allow new tokens to be used
// @param: _token Address of the token to be allowed (felt)
@external
func allowToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*}(_token: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (drip_manager_) = drip_manager.read();
    let (token_mask_) = IDripManager.tokenMask(drip_manager_, _token);
    let (fordbidden_token_mask_) = IDripManager.forbiddenTokenMask(drip_manager_);
    let (is_eq1_) = uint256_eq(Uint256(0,0),token_mask_);
    with_attr error_message("token not allowed"){
        assert is_eq1_ = 0;
    }
    let (is_eq2_) = uint256_eq(Uint256(1,0),token_mask_);
    with_attr error_message("token is underlying"){
        assert is_eq2_ = 0;
    }
    let (low_) = bitwise_and(fordbidden_token_mask_.low, token_mask_.low);
    let (high_) = bitwise_and(fordbidden_token_mask_.high, token_mask_.high);
    let (is_bt_) = uint256_lt(Uint256(0,0), Uint256(low_, high_));
    if (is_bt_ == 1){
        let (low_) = bitwise_xor(fordbidden_token_mask_.low, token_mask_.low);
        let (high_) = bitwise_xor(fordbidden_token_mask_.high, token_mask_.high);
        IDripManager.setForbidMask(drip_manager_, Uint256(low_, high_));
        TokenAllowed.emit(_token);
        return();
    }
    return();
}

// @notice: Forbid a token to be used
// @param: _token Address of the token to be forbidden (felt)
@external
func forbidToken{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr : BitwiseBuiltin*}(_token: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (drip_manager_) = drip_manager.read();
    let (token_mask_) = IDripManager.tokenMask(drip_manager_, _token);
    let (fordbidden_token_mask_) = IDripManager.forbiddenTokenMask(drip_manager_);
    let (is_eq1_) = uint256_eq(Uint256(0,0),token_mask_);
    with_attr error_message("token not allowed"){
        assert is_eq1_ = 0;
    }
    let (is_eq2_) = uint256_eq(Uint256(1,0),token_mask_);
    with_attr error_message("token is underlying"){
        assert is_eq2_ = 0;
    }

    let (low_) = bitwise_and(fordbidden_token_mask_.low, token_mask_.low);
    let (high_) = bitwise_and(fordbidden_token_mask_.high, token_mask_.high);
    let (is_lt_) = uint256_lt(Uint256(0,0), Uint256(low_, high_));
    if (is_lt_ == 0){
        let (low_) = bitwise_or(fordbidden_token_mask_.low, token_mask_.low);
        let (high_) = bitwise_or(fordbidden_token_mask_.high, token_mask_.high);
        IDripManager.setForbidMask(drip_manager_, Uint256(low_, high_));
        TokenForbidden.emit(_token);
        return();
    }
    return();
}

 // CONTRACTS & ADAPTERS MANAGEMENT

// @notice: Allow a new contract
// @param _contract: Address of the contract to be allowed (felt)
// @param _adapter: Type of the contract to be allowed (Uint256)
@external
func allowContract{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_contract: felt, _adapter: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    with_attr error_message("zero address"){
        assert_not_zero(_contract * _adapter);
    }

    let (drip_manager_) = drip_manager.read();
    let (drip_manager_from_adapter_) = IAdapter.dripManager(_adapter);
    with_attr error_message("wrong drip manager from adapter"){
        assert drip_manager_ = drip_manager_from_adapter_;
    }

    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);

    with_attr error_message("drip manager or drip transit exeption"){
        assert_not_zero((_contract - drip_manager_)*(_contract - drip_transit_)*(_adapter - drip_manager_)*(_adapter - drip_transit_));
    }

    let (contract_from_adapter_) = IDripManager.adapterToContract(drip_manager_, _adapter);
    with_attr error_message("adapter used twice"){
        assert contract_from_adapter_ = 0;
    }
    
    IDripManager.changeContractAllowance(drip_manager_, _adapter, _contract);

    let (is_allowed_contract_) = is_allowed_contract.read(_contract);
    
    if(is_allowed_contract_ == 0) {
        let (allowed_contract_length_) = allowed_contract_length.read();
        id_to_allowed_contract.write(allowed_contract_length_, _contract);
        allowed_contract_to_id.write(_contract, allowed_contract_length_);
        allowed_contract_length.write(allowed_contract_length_ + 1);
        is_allowed_contract.write(_contract, 1);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }
    ContractAllowed.emit(_contract, _adapter);
    return();
}

// @notice: Forbid a contract
// @param _contract: Address of the contract to be forbidden (felt)
@external
func forbidContract{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_contract: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    with_attr error_message("zero address for contract"){
        assert_not_zero(_contract);
    }
    let (drip_manager_) = drip_manager.read();
    let (adapter_) = IDripManager.contractToAdapter(drip_manager_, _contract);
    with_attr error_message("contract not allowed adapter"){
        assert_not_zero(adapter_);
    }

    IDripManager.changeContractAllowance(drip_manager_, adapter_, 0);
    IDripManager.changeContractAllowance(drip_manager_, 0, _contract);

    let (allowed_contract_length_) = allowed_contract_length.read();
    let (id_to_remove_) = allowed_contract_to_id.read(_contract);
    let (last_allowed_contract_) = id_to_allowed_contract.read(allowed_contract_length_ - 1);
    id_to_allowed_contract.write(id_to_remove_, last_allowed_contract_);
    allowed_contract_to_id.write(allowed_contract_length_ - 1, 0);
    allowed_contract_to_id.write(last_allowed_contract_, id_to_remove_);
    allowed_contract_length.write(allowed_contract_length_ - 1);
    id_to_allowed_contract.write(allowed_contract_length_ - 1, 0);
    is_allowed_contract.write(_contract, 0);
    ContractForbidden.emit(_contract);
    return();
}

// @notice: Set Limit (minimum and maximum that can be borrowed)
// @param: _minimum_borrowed_amount: Minimum amount that can be borrowed (Uint256)
// @param: _maximum_borrowed_amount: Maximum amount that can be borrowed (Uint256)
@external
func setLimits{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_minimum_borrowed_amount: Uint256, _maximum_borrowed_amount: Uint256){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    set_limits(_minimum_borrowed_amount, _maximum_borrowed_amount);
    return();
}

// @notice: Set Fees
// @param: _fee_interested: Fee for the interest (Uint256)
// @param: _fee_liquidation: the fee for the liquidation (Uint256)
// @param: _liquidation_premium: Premium for the liquidation (Uint256)
// @param: _liquidation_fee_expired: Fee for the expired liquidation (Uint256)
// @param: _liquidation_premium_expired: Premium for the expired liquidation (Uint256)
@external
func setFees{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_fee_interest: Uint256, _fee_liquidation: Uint256, _liquidation_premium: Uint256, _fee_liquidation_expired: Uint256, _liquidation_premium_expired: Uint256){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (is_lt1_) = uint256_le(_fee_interest, Uint256(PRECISION,0));
    let (sum1_) = SafeUint256.add(_liquidation_premium, _fee_liquidation);
    let (is_lt2_) = uint256_le(sum1_, Uint256(PRECISION,0));
    let (sum2_) = SafeUint256.add(_liquidation_premium_expired, _fee_liquidation_expired);
    let (is_lt3_) = uint256_le(sum2_, Uint256(PRECISION,0));
    with_attr error_message("incorrect fees"){
        assert_not_zero(is_lt1_ * is_lt2_ * is_lt3_);
    }
    let (liquidation_discount_) = SafeUint256.sub_le(Uint256(PRECISION,0), _liquidation_premium);
    let (liquidation_discount_expired_) = SafeUint256.sub_le(Uint256(PRECISION,0), _liquidation_premium_expired);
    set_fees(_fee_interest, _fee_liquidation, liquidation_discount_, _fee_liquidation_expired, liquidation_discount_expired_);    
    return();
}

// @notice: Set Increase Forbidden Debt
// @dev: Freeze borrow more and open credit account
@external
func setIncreaseDebtForbidden{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_state: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    set_increase_debt_forbidden(_state);
    return();
}

// @notice: Set max Borrowed Amount per block
// @param: _new_limit: New limit (Uint256)
@external
func setLimitPerBlock{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_new_limit: Uint256){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    set_limit_per_block(_new_limit);
    return();
}

// @notice: Set Drip Expiration Date
// @param: _new_date: New expiration date
@external
func setExpirationDate{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_new_expiration_date: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    set_expiration_date(_new_expiration_date);
    return();
}

// @notice: Emergency liquidation in case 
// @param: _liquidator Address of the liquidator
@external
func addEmergencyLiquidator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_liquidator: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (drip_manager_) = drip_manager.read();
    IDripManager.addEmergencyLiquidator(drip_manager_, _liquidator);
    EmergencyLiquidatorAdded.emit(_liquidator);
    return();
}

// @notice: Remove emergency liquidator
// @param: _liquidator Address of the liquidator
@external
func removeEmergencyLiquidator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_liquidator: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (drip_manager_) = drip_manager.read();
    IDripManager.removeEmergencyLiquidator(drip_manager_, _liquidator);
    EmergencyLiquidatorRemoved.emit(_liquidator);
    return();
}

// @notice: Upgrade Oracle transit
@external
func upgradeOracleTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    let (drip_manager_) = drip_manager.read();
    let (registery_) = RegisteryAccess.registery();
    let (oracle_transit_) = IRegistery.oracleTransit(registery_);
    IDripManager.upgradeOracleTransit(drip_manager_, oracle_transit_);
    OracleTransitUpgraded.emit(oracle_transit_);
    return();
}

// @notice: Upgrade Drip Transit
// @param: _drip_transit 
// @param: _migrate_parameters
@external
func upgradeDripTransit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_drip_transit: felt, _migrate_parameters: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    with_attr error_message("zero address"){
        assert_not_zero(_drip_transit);
    }
    let (drip_manager_) = drip_manager.read();
    let (drip_manager_from_drip_transit_) = IDripTransit.dripManager(_drip_transit);
    with_attr error_message("wrong drip manager from drip transit"){
        assert drip_manager_from_drip_transit_ = drip_manager_;
    }
    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);
    let (max_borrowed_amount_per_block_) = IDripTransit.maxBorrowedAmountPerBlock(drip_transit_);
    let (is_increase_debt_forbidden_) = IDripTransit.isIncreaseDebtForbidden(drip_transit_);
    let (expirable_) = IDripTransit.isExpirable(drip_transit_);
    let (expiration_date_) = IDripTransit.expirationDate(drip_transit_);
    let (minimum_borrowed_amount_, maximum_borrowed_amount_) = IDripTransit.limits(drip_transit_);

    IDripManager.upgradeDripTransit(drip_manager_, _drip_transit);
    if(_migrate_parameters == 1){
        set_limit_per_block(max_borrowed_amount_per_block_);
        set_limits(minimum_borrowed_amount_, maximum_borrowed_amount_);
        set_increase_debt_forbidden(is_increase_debt_forbidden_);
        if(expirable_ == 1){
            set_expiration_date(expiration_date_);
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar syscall_ptr = syscall_ptr;
            tempvar pedersen_ptr = pedersen_ptr;
            tempvar range_check_ptr = range_check_ptr;
        }
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }
    DripTransitUpgraded.emit(_drip_transit);
    return();
}

// @notice: Upgrade Drip Configurator
// @param: _drip_configurator
@external
func upgradeConfigurator{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_drip_configurator: felt){
    alloc_locals;
    RegisteryAccess.assert_only_owner();
    with_attr error_message("zero address"){
        assert_not_zero(_drip_configurator);
    }
    let (drip_manager_) = drip_manager.read();
    let (drip_manager_from_drip_configurator_) = IDripConfigurator.dripManager(_drip_configurator);
    with_attr error_message("wrong drip manager from drip configurator"){
        assert drip_manager_from_drip_configurator_ = drip_manager_;
    }
    IDripManager.setConfigurator(drip_manager_, _drip_configurator);
    DripConfiguratorUpgraded.emit(_drip_configurator);
    return();
}

// @notice: get allowed contract length
// @return: allowed contract length
@view
func allowedContractsLength{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (allowedContractsLength: felt){
    alloc_locals;
    let (allowed_contract_length_) = allowed_contract_length.read();
    return(allowed_contract_length_,);
}

// @notice: get id to allowed contract
// @return: allowed contract
@view
func idToAllowedContract{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_id: felt) -> (allowedContract: felt){
    alloc_locals;
    let (allowed_contract_) = id_to_allowed_contract.read(_id);
    return(allowed_contract_,);
}

// @notice: get allowed contract to id
// @return: allowed contract id
@view
func allowedContractToId{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_allowed_contract: felt) -> (id: felt){
    alloc_locals;
    let (id_) = allowed_contract_to_id.read(_allowed_contract);
    return(id_,);
}

// @notice: check if a contract is allowed
// @return: state True if allowed
@view
func isAllowedContract{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_contract: felt) -> (state: felt){
    alloc_locals;
    let (state_) = is_allowed_contract.read(_contract);
    return(state_,);
}

// @notice: get Drip manager address
// @return: Drip manager address
@view
func dripManager{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (dripManager: felt){
    alloc_locals;
    let (drip_manager_) = drip_manager.read();
    return(drip_manager_,);
}

// Internals

// @notice: list of allowed token
// @custom: internal function
// @param: _allowed_token (AllowedToken*)
// @param: _allowed_token_len (felt)
func allow_token_list{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_allowed_tokens_len: felt, _allowed_tokens: AllowedToken*){
    alloc_locals;
    if(_allowed_tokens_len == 0){
        return();
    }
    add_token(_allowed_tokens[0].address);
    set_liquidation_threshold(_allowed_tokens[0].address, _allowed_tokens[0].liquidation_threshold);
    return allow_token_list(_allowed_tokens_len - 1, _allowed_tokens + AllowedToken.SIZE);
}

// @notice : add token
// @custom: internal function
// @param: _token (felt)
func add_token{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt){
    
    with_attr error_message("zero address for token"){
        assert_not_zero(_token);
    }
    //TODO: Check ERC20 contract
    // try call balanceOf ?
    let (_) = IERC20.balanceOf(_token, 22);

    let (drip_manager_)= drip_manager.read();
    let (oracle_transit_) = IDripManager.oracleTransit(drip_manager_);
    let (derivative_price_feed_) = IOracleTransit.derivativePriceFeed(oracle_transit_, _token);
    let (pair_id_) = IOracleTransit.primitivePairId(oracle_transit_, _token);
    let (is_lp_) = IOracleTransit.isLiquidityToken(oracle_transit_, _token);
    with_attr error_message("no price feed for token"){
        assert_not_zero(derivative_price_feed_ + pair_id_ + is_lp_);
    }
    IDripManager.addToken(drip_manager_, _token);
    TokenAllowed.emit(_token);
    return();
}

// @notice: set liquidation threshold
// @custom: internal function
// @param: _token token address
// @param: _liquidation_threshold liquidation threshold (Uint256)
func set_liquidation_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_token: felt, _liquidation_threshold: Uint256){
    let (underlying_) = underlying.read();
    with_attr error_message("underlying is token"){
        assert_not_zero(underlying_ - _token);
    }

    let (drip_manager_) = drip_manager.read();
    let (underlying_liquidation_threshold_) = IDripManager.liquidationThreshold(drip_manager_, underlying_);
    let (is_lt1_) = uint256_lt(Uint256(0,0), _liquidation_threshold);
    let (is_lt2_) = uint256_lt(_liquidation_threshold, underlying_liquidation_threshold_);
    with_attr error_message("incorrect liquidation threshold"){
        assert_not_zero(is_lt1_ * is_lt2_);
    }

    IDripManager.setLiquidationThreshold(drip_manager_, _token, _liquidation_threshold);
    TokenLiquidationThresholdUpdated.emit(_token, _liquidation_threshold);
    return();
}

// @notice: set limit per block
// @param: _new_limit_per_block limit per block (Uint256)
func set_limit_per_block{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_new_limit_per_block: Uint256){
    let (drip_manager_) = drip_manager.read();
    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);
    let (max_borrowed_amount_per_block_) = IDripTransit.maxBorrowedAmountPerBlock(drip_transit_);
    let (_, max_borrowed_amount_) = IDripTransit.limits(drip_transit_);
    let (is_lt_) = uint256_lt(_new_limit_per_block, max_borrowed_amount_);
    with_attr error_message("incorrect limit"){
        assert is_lt_ = 0;
    }
    IDripTransit.setMaxBorrowedAmountPerBlock(drip_transit_, _new_limit_per_block);
    LimitPerBlockUpdated.emit(_new_limit_per_block);
    return();
}

// @notice: set limits
// @custom: internal function
// @param: _new_min_borrowed_amount min borrowed amount (Uint256)
// @param: _new_max_borrowed_amount max borrowed amount (Uint256)
func set_limits{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_minimum_borrowed_amount: Uint256, _maximum_borrowed_amount: Uint256){
    let (drip_manager_) = drip_manager.read();
    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);
    let (max_borrowed_amount_per_block_) = IDripTransit.maxBorrowedAmountPerBlock(drip_transit_);
    let (is_lt_1) = uint256_lt(_minimum_borrowed_amount, _maximum_borrowed_amount);
    let (is_lt_2) = uint256_lt(_maximum_borrowed_amount, max_borrowed_amount_per_block_);
    with_attr error_message("incorrect limit"){
        assert_not_zero(is_lt_1 * is_lt_2);
    }
    IDripTransit.setDripLimits(drip_transit_, _minimum_borrowed_amount, _maximum_borrowed_amount);
    LimitsUpdated.emit(_minimum_borrowed_amount, _maximum_borrowed_amount);
    return();
}

// @notice: set increase debt forbidden
// @custom: internal function
// @param: _state state
func set_increase_debt_forbidden{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_state: felt){
    alloc_locals;
    let (drip_manager_) = drip_manager.read();
    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);
    IDripTransit.setIncreaseDebtForbidden(drip_transit_, _state);
    IncreaseDebtForbiddenStateChanged.emit(_state);
    return();
}

// @notice: set expiration date for drip
// @custom: internal function
// @param: _new_expiration_date expiration date 
func set_expiration_date{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_new_expiration_date: felt){
    alloc_locals;
    let (drip_manager_) = drip_manager.read();
    let (drip_transit_) = IDripManager.dripTransit(drip_manager_);
    let (current_expiration_date_) = IDripTransit.expirationDate(drip_transit_);
    let (block_timestamp_) = get_block_timestamp();
    let (is_lt_) = uint256_lt(Uint256(block_timestamp_, 0), Uint256(_new_expiration_date,0));
    let (is_le_) = uint256_le(Uint256(current_expiration_date_,0),Uint256(_new_expiration_date,0));
    with_attr error_message("incorrect expiration date"){
        assert_not_zero(is_lt_ * is_le_);
    }
    IDripTransit.setExpirationDate(drip_transit_, _new_expiration_date);
    ExpirationDateUpdated.emit(_new_expiration_date);
    return();
}

// @notice: set fees
// @custom: internal function
// @param: _fee_interest fee interest (Uint256)
// @param: _fee_liquidation fee liquidation (Uint256)
// @param: _liquidation_discount liquidation discount (Uint256)
// @param: _fee_liquidation_expired fee liquidation expired (Uint256)
// @param: _liquidation_discount_expired liquidation discount expired (Uint256)
func set_fees{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        _fee_interest: Uint256,
        _fee_liquidation: Uint256,
        _liquidation_discount: Uint256,
        _fee_liquidation_expired: Uint256,
        _liquidation_discount_expired: Uint256){
    alloc_locals;
    let (drip_manager_) = drip_manager.read();
    let (underlying_) = underlying.read();
    let (lt_underlying_) = IDripManager.liquidationThreshold(drip_manager_, underlying_);
    let (new_lt_underlying_) = SafeUint256.sub_le(_liquidation_discount, _fee_liquidation);
    let (is_eq_) = uint256_eq(lt_underlying_, new_lt_underlying_);
    if(is_eq_ == 0){
        update_liquidation_threshold(new_lt_underlying_);
        TokenLiquidationThresholdUpdated.emit(underlying_, new_lt_underlying_);
        tempvar syscall_ptr= syscall_ptr;
        tempvar pedersen_ptr= pedersen_ptr;
        tempvar range_check_ptr= range_check_ptr;
    } else {
        tempvar syscall_ptr= syscall_ptr;
        tempvar pedersen_ptr= pedersen_ptr;
        tempvar range_check_ptr= range_check_ptr;
    }
    IDripManager.setFees(drip_manager_, _fee_interest, _fee_liquidation, _liquidation_discount, _fee_liquidation_expired, _liquidation_discount_expired);
    FeesUpdated.emit(_fee_interest, _fee_liquidation, _liquidation_discount, _fee_liquidation_expired, _liquidation_discount_expired);
    return();
}

// @notice: Update liquidation threshold
// @custom: internal function
// @param: _lt_underlying new liquidation threshold (Uint256)
func update_liquidation_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_lt_underlying: Uint256){
    let (underlying_) = underlying.read();
    let (drip_manager_) = drip_manager.read();
    IDripManager.setLiquidationThreshold(drip_manager_, underlying_, _lt_underlying);
    let (length_) = IDripManager.allowedTokensLength(drip_manager_);
    loop_liquidation_threshold(length_, drip_manager_, _lt_underlying);
    return();
}

// @notice: loop for update liquidation threshold
// @custom: internal function
// @param: _length length of allowed tokens
// @param: _drip_manager drip manager
// @param: _lt_underlying new liquidation threshold (Uint256)
func loop_liquidation_threshold{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(_len: felt, _drip_manager: felt,_lt_underlying: Uint256){
    // we din't need to set the underlying lt directly
    if(_len == 1){
        return();
    }
    let (token_) = IDripManager.tokenById(_drip_manager, _len - 1);
    let (lt_token_) = IDripManager.liquidationThreshold(_drip_manager, token_);
    let (is_lt_) = uint256_lt(_lt_underlying, lt_token_);
    if(is_lt_ == 1){
        IDripManager.setLiquidationThreshold(_drip_manager, token_, _lt_underlying);
        TokenLiquidationThresholdUpdated.emit(token_, _lt_underlying);
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    } else {
        tempvar syscall_ptr = syscall_ptr;
        tempvar pedersen_ptr = pedersen_ptr;
        tempvar range_check_ptr = range_check_ptr;
    }
    return loop_liquidation_threshold(_len - 1,  _drip_manager, _lt_underlying);
}
