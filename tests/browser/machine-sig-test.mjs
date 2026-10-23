// tests/browser/machine-sig-test.mjs — the lender's signature, end to end.
//
// The goldens below are the Scheme side's own answers for the same bytes:
// binding-verifiers.scm's ed25519-pubkey->did-key and cesr.scm's
// cesr-bytes->qb64 — so the JS encoders are pinned to the wire format
// the doors actually decode, not to themselves.
//
// Run: node tests/browser/machine-sig-test.mjs

import { harness } from "./assert.mjs";
import { base58Encode, base58Decode, pubkeyToDidKey, didKeyToPubkey,
         cesrQb64Sig, makeSeedSigner, verifyDidKeySig }
    from "../../browser/lib/machine-sig.js";
import { emitReceipt } from "../../browser/app/machine-executor.js";

const { check, section, done } = harness();

// seed = bytes 1..32 — the keypair signify-portable derives for it
const seed = new Uint8Array(32).map((_, i) => i + 1);
const EXPECTED_DID = "did:key:z6MkneMkZqwqRiU5mJzSG3kDwzt9P8C59N4NGTfBLfSGE7c7";
const EXPECTED_SIG = "0BCq3OZbMqAksgtjvkrYCtffQSbTgLU4tw5bEvpo0DdefAqv557Bkf9VeaaV-taJKKheFlDktllI1r6v-5TvN-cH";

section("the encodings, pinned to the Scheme encoders");
check("did:key for the known pubkey matches the Scheme encoder",
      pubkeyToDidKey(new Uint8Array(32).map((_, i) => i)) === "did:key:z6MkeTGwHmLmuCmgg4ABYhzWVh6ZX7hTwWt8gguAretUfc9c");
check("qb64 '0B' for a known 64-byte body matches cesr-bytes->qb64",
      cesrQb64Sig(new Uint8Array(64).map((_, i) => i))
          === "0BAAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4_");
check("base58 round-trips",
      base58Encode(base58Decode("3yZe7d")) === "3yZe7d"
      && base58Encode(base58Decode("6MkeTGwHmLmu")) === "6MkeTGwHmLmu");
check("didKeyToPubkey is pubkeyToDidKey's inverse",
      (() => {
          const pub = new Uint8Array(32).map((_, i) => 255 - i);
          const back = didKeyToPubkey(pubkeyToDidKey(pub));
          return back && back.every((b, i) => b === pub[i]);
      })());
check("didKeyToPubkey refuses non-ed25519 and non-did strings",
      didKeyToPubkey("did:keri:EABC") === null && didKeyToPubkey("did:key:x1a") === null);

section("the signature itself");
check("the seed signer derives the Scheme-side did:key",
      makeSeedSigner(seed).did === EXPECTED_DID);
check("the seed signer's sig over 'deadbeef' is the Scheme-side sig byte for byte",
      makeSeedSigner(seed).sign("deadbeef") === EXPECTED_SIG);
check("verifyDidKeySig accepts a real sig and refuses forged ones",
      (() => {
          const signer = makeSeedSigner(seed);
          const sig = signer.sign("receipt-digest-hex");
          return verifyDidKeySig(signer.did, "receipt-digest-hex", sig)
              && !verifyDidKeySig(signer.did, "tampered-digest", sig)
              && !verifyDidKeySig("did:key:z6MkeTGwHmLmuCmgg4ABYhzWVh6ZX7hTwWt8gguAretUfc9c",
                                  "receipt-digest-hex", sig);
      })());

section("the receipt, signed");
{
    const signer = makeSeedSigner(seed);
    const receipt = await emitReceipt({
        env: { kind: "exec", inputHash: "in:1", image: "js", entrypoint: "m" },
        result: { ok: true }, seconds: 0.5,
        bridgeJobId: "claim-1", signer,
    });
    check("emitReceipt signs the digest under the signer's did:key",
          receipt.lenderDid === EXPECTED_DID
          && typeof receipt.lenderSig === "string"
          && verifyDidKeySig(EXPECTED_DID, receipt.digest, receipt.lenderSig));
}
{
    const receipt = await emitReceipt({
        env: { kind: "exec", inputHash: "in:1", image: "js", entrypoint: "m" },
        result: { ok: true }, seconds: 0.5,
        bridgeJobId: "claim-1",
    });
    check("emitReceipt without a signer still answers unverifiable honestly",
          receipt.lenderSig === null && typeof receipt.digest === "string");
}

done();
