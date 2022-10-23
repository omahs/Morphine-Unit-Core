%lang starknet

from starkware.cairo.common.uint256 import Uint256

struct Router {
    address: felt,
    type: felt,
}

struct Path {
    token_in: felt,
    token_out: felt,
}

@contract_interface
namespace ICommercium {
    func solver_registery() -> (address: felt) {
    }

    func trade_executor() -> (address: felt) {
    }

    func get_solver_amount(
        amount_in: Uint256, token_in: felt, token_out: felt, solver_id: felt
    ) -> (amount_out: Uint256) {
    }

    func get_solver_amount_exact_out(
        amount_in: Uint256, token_in: felt, token_out: felt, solver_id: felt
    ) -> (amount_out: Uint256) {
    }

    func get_solver_amount_and_path(
        amount_in: Uint256, token_in: felt, token_out: felt, solver_id: felt
    ) -> (
        router_len: felt,
        router: Router*,
        path_len: felt,
        path: Path*,
        amounts_len: felt,
        amounts: felt*,
        amount_out: Uint256,
    ) {
    }

    func get_amounts_out(amount_in: Uint256, path_len: felt, path: felt*) -> (
        amounts_len: felt, amounts: Uint256*
    ) {
    }

    func get_multiple_solver_amounts(
        amount_in: Uint256, token_in: felt, token_out: felt, solver_ids_len: felt, solver_ids: felt*
    ) -> (amounts_len: felt, amounts: Uint256*) {
    }

    func swap_exact_tokens_for_tokens(
        amount_in: Uint256,
        amount_out_min: Uint256,
        path_len: felt,
        path: felt*,
        to: felt,
        deadline: felt,
    ) -> (amounts_len: felt, amounts: Uint256*) {
    }

    func swap_tokens_for_exact_tokens(
        amount_out: Uint256,
        amount_in_max: Uint256,
        path_len: felt,
        path: felt*,
        to: felt,
        deadline: felt,
    ) -> (amounts_len: felt, amounts: Uint256*) {
    }

    func swap_with_solver(
        token_in: felt,
        token_out: felt,
        amount_in: Uint256,
        amount_out_min: Uint256,
        to: felt,
        solver_id: felt,
    ) -> (received_amount: Uint256) {
    }

    func swap_with_solver_exact_out(
        token_in: felt,
        token_out: felt,
        amount_out: Uint256,
        max_amount_in: Uint256,
        to: felt,
        solver_id: felt,
    ) -> (in_amount: Uint256) {
    }

    func swap_with_path(
        routers_len: felt,
        routers: Router*,
        path_len: felt,
        path: Path*,
        amounts_len: felt,
        amounts: felt*,
        amount_in: Uint256,
        min_amount_out: Uint256,
    ) -> (received_amount: Uint256) {
    }

    func set_solver_registry(new_registry: felt) {
    }

    func set_executor(executor_hash: felt) {
    }

    func retrieve_token(
        token_len: felt, token: felt*, token_amount_len: felt, token_amount: Uint256*
    ) {
    }
}
