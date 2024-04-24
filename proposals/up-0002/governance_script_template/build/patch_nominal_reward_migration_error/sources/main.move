
script {

  use diem_framework::diem_governance;
  use ol_framework::proof_of_fee;

  fun main(proposal_id: u64){
      let framework_signer = diem_governance::resolve_multi_step_proposal(
          proposal_id,
          @0000000000000000000000000000000000000000000000000000000000000001,
          vector[],
      );
      // Set the nominal_reward to the value prior to v7.0.1 hard fork
      proof_of_fee::genesis_migrate_reward(&framework_signer, 178204815);
  }
}
