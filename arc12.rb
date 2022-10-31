# frozen_string_literal: true

require 'tealrb'
require 'pry'

class Vault < TEALrb::Contract
  @version = 8

  # @abi
  # @create
  # Method called for creation of the vault
  # @param receiver [Account] The account that can claim ASAs from this vault
  # @param sender [Account]
  def create(receiver, sender)
    global['assets'] = 0
    global['creator'] = sender
    global['receiver'] = receiver
    global['master'] = global.caller_application_id
  end

  # @abi
  # Opts into the given asa
  # @param sender [Account] The account that is sending the ASA
  # @param asa [Asset] The asset to opt-in to
  # @param mbr_payment [Pay] The payment to cover this contracts MBR
  def opt_in(sender, asa, mbr_payment)
    $asa_bytes = itob(asa)
    assert !box_exists?($asa_bytes)
    assert mbr_payment.sender == sender
    assert mbr_payment.receiver == global.current_application_address

    $pre_mbr = global.current_application_address.min_balance

    global['assets'] = global['assets'] + 1

    box_create($asa_bytes, 32)
    box[$asa_bytes] = sender

    # // Opt into ASA
    inner_txn.begin
    inner_txn.type_enum = txn_type.asset_transfer
    inner_txn.asset_receiver = global.current_application_address
    inner_txn.asset_amount = 0
    inner_txn.fee = 0
    inner_txn.xfer_asset = asa
    inner_txn.submit

    assert mbr_payment.amount == global.current_application_address.min_balance - $pre_mbr
  end

  # @abi
  # @on_completion [DeleteApplication]
  def delete
    assert global.current_application_address.balance == 0
    assert global.caller_application_id == global['master']
  end

  # @abi
  # Sends the ASA to the intended receiver
  # @param asa [Asset] The ASA to send
  # @param creator [Account] The account that funded the MBR for the application
  # @param receiver [Account] The account that can claim from this vault
  # @param asa_mbr_funder [Account] The account that funded the MBR for the ASA
  def claim(asa, receiver, creator, asa_mbr_funder)
    $asa_bytes = itob(asa)

    assert box_exists?($asa_bytes)
    assert asa_mbr_funder == box[$asa_bytes]
    assert receiver == global['receiver']
    assert creator == global['creator']
    assert this_txn.sender == receiver

    $initial_mbr = global.current_application_address.min_balance

    box_del $asa_bytes

    # // Close ASA to receiver
    inner_txn.begin
    inner_txn.type_enum = txn_type.asset_transfer
    inner_txn.asset_receiver = receiver
    inner_txn.fee = 0
    inner_txn.asset_amount = this_txn.sender.asset_balance(asa)
    inner_txn.xfer_asset = asa
    inner_txn.asset_close_to = receiver
    inner_txn.submit

    # // Send ASA MBR to funder
    inner_txn.begin
    inner_txn.type_enum = txn_type.pay
    inner_txn.receiver = asa_mbr_funder
    inner_txn.amount = global.current_application_address.min_balance - $initial_mbr
    inner_txn.fee = 0
    inner_txn.submit

    global['assets'] = global['assets'] - 1

    if global['assets'] == 0
      inner_txn.begin
      inner_txn.type_enum = txn_type.pay
      inner_txn.receiver = creator
      inner_txn.amount = global.current_application_address.min_balance
      inner_txn.fee = 0
      inner_txn.close_remainder_to = receiver
      inner_txn.submit

      $delete_vault_txn = group_txns[this_txn.group_index + 1]
      assert $delete_vault_txn.application_id == global['master']
      assert $delete_vault_txn.on_completion == int('DeleteApplication')
    end
  end
end

class Master < TEALrb::Contract
  @version = 8
  # @abi
  # Create Vault
  # @param receiver [Account]
  # @param mbr_payment [Pay]
  # @return [Uint64] Application ID of the vault for receiver
  def create_vault(receiver, mbr_payment)
    assert !box_exists?(receiver)
    assert mbr_payment.receiver == global.current_application_address
    assert mbr_payment.sender == this_txn.sender
    assert mbr_payment.close_remainder_to == global.zero_address

    $pre_create_mbr = global.current_application_address.min_balance

    # // Create vault
    inner_txn.begin
    inner_txn.type_enum = txn_type.application_call
    inner_txn.application_id = 0
    inner_txn.approval_program = byte_b64 Vault.new.compiled_program
    inner_txn.on_completion = int('NoOp')
    inner_txn.accounts = receiver
    inner_txn.accounts = this_txn.sender
    inner_txn.fee = 0
    # TODO: inner_txn.application_args = Vault.create
    inner_txn.submit

    # // Fund vault with account MBR
    inner_txn.begin
    inner_txn.type_enum = txn_type.pay
    inner_txn.receiver = this_txn.created_application_id.address
    inner_txn.amount = global.min_balance
    inner_txn.fee = 0
    inner_txn.submit

    box_create receiver, 32
    box[receiver] = itob this_txn.created_application_id

    assert mbr_payment.amount == (global.current_application_address.min_balance - $pre_create_mbr) + global.min_balance

    return itob this_txn.created_application_id
  end

  # @abi
  # @param receiver [Account]
  # @param vault_axfer [Axfer]
  def verify_axfer(receiver, vault_axfer)
    assert box_exists?(receiver)
    assert vault_axfer.receiver == box[receiver]
    assert vault_axfer.close_remainder_to == global.zero_address
  end

  # @abi
  # @param receiver [Account]
  # @return [Uint64] Application ID of the vault for receiver
  def get_vault_id(receiver)
    assert box_exists?(receiver)
    return box[receiver]
  end

  # @abi
  # @param receiver [Account]
  # @return [Address] Address of the vault for receiver
  def get_vault_addr(receiver)
    assert box_exists?(receiver)
    return app(btoi(box[receiver])).address
  end

  # @abi
  # @param receiver [Account]
  # @param vault [Application]
  # @param creator [Account]
  def delete_vault(receiver, vault, creator)
    assert box_exists?(receiver)
    assert vault == btoi(box[receiver])
    $vault_creator = vault.global_value('creator')
    assert $vault_creator == creator

    $pre_delete_mbr = global.current_application_address.min_balance

    # // Delete vault
    inner_txn.begin
    inner_txn.type_enum = txn_type.application_call
    inner_txn.application_id = btoi(box[receiver])
    inner_txn.on_completion = int('DeleteApplication')
    inner_txn.fee = 0
    inner_txn.submit

    # // Send vault MBR to creator
    inner_txn.begin
    inner_txn.type_enum = txn_type.pay
    inner_txn.receiver = $vault_creator
    inner_txn.amount = global.current_application_address.min_balance - $pre_delete_mbr
    inner_txn.fee = 0
    inner_txn.submit
  end
end

Vault.new.dump
Master.new.dump
