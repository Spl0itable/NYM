// Standalone Worker whose only job is to host the NymLedger Durable Object
export { NymLedger } from "../functions/api/_ledger.js";

export default {
  async fetch() {
    return new Response("nym-ledger", { status: 200 });
  }
};
