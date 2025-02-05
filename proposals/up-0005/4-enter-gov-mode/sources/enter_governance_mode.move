
script {
  // Enter Governance Mode, and disable coin transactions
  use diem_framework::diem_governance;
  use ol_framework::ol_features_constants;
  use std::features;
  use std::vector;

  fun main(proposal_id: u64){
      let next_hash = vector::empty();
      let framework_signer = diem_governance::resolve_multi_step_proposal(proposal_id, @0000000000000000000000000000000000000000000000000000000000000001, next_hash);
      // set governance mode
      let gov_mode_id = ol_features_constants::get_governance_mode();
      features::change_feature_flags(&framework_signer, vector::singleton(gov_mode_id), vector::empty());

      // TO EXIT GOVERNANCE MODE REVERSE THE VECTORS:
      // features::change_feature_flags(&framework_sig, vector::empty(), vector::singleton(gov_mode_id));
  }
}
