[# EIP-712: The Magic Behind Signed Contracts

## What Even Is EIP-712?

You know how you sign documents in real life? You put your signature on a piece of paper, and everyone knows it's really you?

**EIP-712** is Ethereum's way of doing that, but for *structured data* on the blockchain.

Instead of signing a random blob of bytes (which is scary and confusing), you sign something that looks like:

```
AgentPermit {
  agent: 0x1234...
  permissions: 0xfff...
  expiry: 1704067200
  nonce: 5
  maxCalls: 100
  bounty: 1000000000000000000
}
```

You can **see what you're signing**. It's readable. It's safe. It's EIP-712.

---

## The Problem It Solves

### Before EIP-712 (The Bad Old Days)

You'd call a function like:

```solidity
permit(bytes calldata signature)
```

And you'd have NO IDEA what was in that signature. It's just... bytes. Could be anything. Could be signing away your house. Could be signing your cat away.

So you'd have to blindly trust that the signature is for what you think it's for.

**Terrifying.**

### After EIP-712 (The Good New Days)

Now you can see:

```solidity
permit(
  address agent,
  bytes32 permissions,
  uint256 expiry,
  uint256 nonce,
  uint256 maxCalls,
  uint256 bounty,
  bytes32 r,
  bytes32 s,
  uint8 v
)
```

And you KNOW what you're signing because the contract shows you the struct definition first.

**Safe.**

---

## How It Actually Works (Simple Version)

### Step 1: Define Your Struct

You decide what data you want signed:

```
struct AgentPermit {
  address agent;
  bytes32 permissions;
  uint256 expiry;
  uint256 nonce;
  uint256 maxCalls;
  uint256 bounty;
}
```

This is just... a template. A blueprint. What fields matter.

### Step 2: Compute the Typehash

This is the weird part. For your struct, you compute a hash of its signature:

```
TYPEHASH = keccak256("AgentPermit(address agent,bytes32 permissions,uint256 expiry,uint256 nonce,uint256 maxCalls,uint256 bounty)")
```

This is a **fingerprint** of your struct definition.

Why? Because if someone tries to change the struct definition, this hash changes, and nothing works anymore. It's tamper-proof.

### Step 3: Encode the Data

You pack all your data into a hash:

```
structHash = keccak256(
  TYPEHASH,
  agent,
  permissions,
  expiry,
  nonce,
  maxCalls,
  bounty
)
```

This is like... taking all your data and turning it into a fingerprint.

### Step 4: Build the Domain Separator

This is the clever bit. You create a hash that represents **this specific contract on this specific chain**:

```
domainSeparator = keccak256(
  DOMAIN_TYPEHASH,
  keccak256("GhostOperator"),    // contract name
  keccak256("1"),                 // version
  chainId,                         // which blockchain
  address(this)                    // which contract
)
```

Why? Because if someone tries to use your signature on a *different* contract or a *different chain*, it won't work.

**Replay protection.**

### Step 5: Build the Final Digest

Now you combine everything:

```
digest = keccak256(
  "\x19\x01",           // EIP-712 magic prefix
  domainSeparator,      // where we are
  structHash            // what we're signing
)
```

This digest is what you actually sign with your private key.

### Step 6: Sign It

```
(v, r, s) = sign(digest, privateKey)
```

You get back three numbers that prove you signed it.

### Step 7: Verify On Chain

The contract receives `v`, `r`, `s` and does:

```
signer = ecrecover(digest, v, r, s)
require(signer == msg.sender, "Invalid signature!")
```

This magically recovers your address from the signature.

If it matches your address, **you signed it.**

**Done.**

---

## Why This is Brilliant

### You Can See What You're Signing

Before EIP-712, wallets would show:

```
Sign this transaction?
Data: 0x1234567890abcdef...
```

Meaningless gibberish.

With EIP-712, wallets show:

```
Sign this transaction?
Agent: 0x1234...
Permissions: 0xfff...
Expiry: Tuesday, Jan 1, 2025
Nonce: 5
Max Calls: 100
Bounty: 1 ETH
```

**You can actually read it.**

### It Can't Be Replayed

If you sign a permit on Ethereum mainnet, someone can't take that same signature and use it on Arbitrum or Optimism. The `domainSeparator` prevents it.

### It's Standardized

Every wallet implements EIP-712 the same way. MetaMask, Ledger, Gnosis Safe, all of them. It's a universal standard.

### It Proves Intent

When you sign with EIP-712, you're proving you understood exactly what you were signing. No ambiguity. No "I didn't read the fine print."

---

## Real Example: GhostOperator

When you authorize an agent in GhostOperator, you're signing:

```
AgentPermit {
  agent: BobTheRobot (0x5678...)
  permissions: 0xfff... (can swap tokens only)
  expiry: 1704067200 (next Tuesday)
  nonce: 5 (this is your 5th authorization)
  maxCalls: 100 (Bob can do this 100 times)
  bounty: 1 ETH (you pay Bob 1 ETH per task)
}
```

You sign this with MetaMask. MetaMask shows you all these fields. You click "sign."

Now the contract has your signature. It verifies:
1. ✅ Is this really your signature? (ecrecover)
2. ✅ Is this for THIS contract on THIS chain? (domainSeparator)
3. ✅ Is this the right struct definition? (typehash)
4. ✅ Have you authorized Bob? (struct matches your intent)

**All checks pass. Bob gets his permissions.**

---

## How to Use EIP-712 (Quick Reference)

### For Users (You're Signing)
1. See what you're signing (thanks EIP-712)
2. Click "sign" in your wallet
3. Done. Your signature proves intent.

### For Developers (Writing Contracts)

1. Define your struct
2. Compute the typehash (off-chain)
3. In your contract, compute structHash from parameters
4. Compute digest = keccak256("\x19\x01", domainSeparator, structHash)
5. Use ecrecover to get the signer
6. Verify signer == expected authority

```solidity
// Pseudo-code (not real Solidity)
function permit(
  address agent,
  bytes32 permissions,
  uint256 expiry,
  uint256 nonce,
  uint256 maxCalls,
  uint256 bounty,
  uint8 v, bytes32 r, bytes32 s
) public {
  bytes32 structHash = keccak256(abi.encode(
    TYPEHASH,
    agent,
    permissions,
    expiry,
    nonce,
    maxCalls,
    bounty
  ));
  
  bytes32 digest = keccak256(abi.encodePacked(
    "\x19\x01",
    DOMAIN_SEPARATOR,
    structHash
  ));
  
  address signer = ecrecover(digest, v, r, s);
  require(signer == msg.sender, "Invalid signature!");
  
  // Do the thing
}
```

---

## The Magic Explained (Sort Of)

The `"\x19\x01"` prefix is EIP-191's way of saying "this is a structured signed message, not a transaction."

The domainSeparator ties it to THIS specific contract, so:
- Different contract = different hash = signature doesn't work = replay prevented
- Different chain = different chainId in domainSeparator = signature doesn't work = cross-chain replay prevented

The typehash ties it to THIS specific struct definition, so:
- Someone changes the struct = typehash changes = signature doesn't work = tampering detected

**Everything is tamper-proof because changing ANYTHING changes the hash.**

---

## Why EIP-712 Rocks

✅ You can see what you're signing  
✅ Replay protection (chain-specific, contract-specific)  
✅ Standardized across all wallets  
✅ Mathematically proven to be secure  
✅ Gas-efficient (you don't store the data on-chain, you pass it in the call)  

---

## Next Steps

- Learn how to compute typehashes (hint: use ethers.utils.id())
- Look at GhostOperator.huff to see EIP-712 in action (pure assembly version)
- Sign some contracts with MetaMask and watch it display your data
- Never trust a smart contract that asks you to sign opaque blobs again

---

**EIP-712: Math That Proves You Meant It**

Because your signature should mean something.
](EIP-712: The Magic Behind Signed Contracts
What Even Is EIP-712?
You know how you sign documents in real life? You put your signature on a piece of paper, and everyone knows it’s really you?

EIP-712 is Ethereum’s way of doing that, but for structured data on the blockchain.

Instead of signing a random blob of bytes (which is scary and confusing), you sign something that looks like:

text
AgentPermit {
  agent: 0x1234...
  permissions: 0xfff...
  expiry: 1704067200
  nonce: 5
  maxCalls: 100
  bounty: 1000000000000000000
}
You can see what you’re signing. It’s readable. It’s safe. It’s EIP-712.

Wait, hold up.
“Seeing what you’re signing” only happens if the dapp (website) actually uses eth_signTypedData_v4 to ask your wallet to display those fields. If a contract just takes a raw bytes signature and the dapp doesn’t give your wallet the struct info, you’re back to squinting at hex. So don’t just trust the contract—trust that the frontend shows you the goods.

The Problem It Solves
Before EIP-712 (The Bad Old Days)
You’d call a function like:

solidity
permit(bytes calldata signature)
And you’d have NO IDEA what was in that signature. It’s just… bytes. Could be anything. Could be signing away your house. Could be signing your cat away.

So you’d have to blindly trust that the signature is for what you think it’s for.

Terrifying.

After EIP-712 (The Good New Days)
Now you can see:

solidity
permit(
  address agent,
  bytes32 permissions,
  uint256 expiry,
  uint256 nonce,
  uint256 maxCalls,
  uint256 bounty,
  bytes32 r,
  bytes32 s,
  uint8 v
)
And you KNOW what you’re signing because the contract shows you the struct definition first.

Safe.

How It Actually Works (Simple Version)
Step 1: Define Your Struct
You decide what data you want signed:

text
struct AgentPermit {
  address agent;
  bytes32 permissions;
  uint256 expiry;
  uint256 nonce;
  uint256 maxCalls;
  uint256 bounty;
}
This is just… a template. A blueprint. What fields matter.

Step 2: Compute the Typehash
This is the weird part. For your struct, you compute a hash of its signature:

text
TYPEHASH = keccak256("AgentPermit(address agent,bytes32 permissions,uint256 expiry,uint256 nonce,uint256 maxCalls,uint256 bounty)")
This is a fingerprint of your struct definition.

Why? Because if someone tries to change the struct definition, this hash changes, and nothing works anymore. It’s tamper-proof.

Step 3: Encode the Data
You pack all your data into a hash:

text
structHash = keccak256(
  TYPEHASH,
  agent,
  permissions,
  expiry,
  nonce,
  maxCalls,
  bounty
)
This is like… taking all your data and turning it into a fingerprint.

Step 4: Build the Domain Separator
This is the clever bit. You create a hash that represents this specific contract on this specific chain:

text
domainSeparator = keccak256(
  DOMAIN_TYPEHASH,
  keccak256("GhostOperator"),    // contract name
  keccak256("1"),                 // version
  chainId,                         // which blockchain
  address(this)                    // which contract
)
Why? Because if someone tries to use your signature on a different contract or a different chain, it won’t work.

Replay protection.
(But only if you actually include the contract address—some implementations forget. Don’t be that person.)

Step 5: Build the Final Digest
Now you combine everything:

text
digest = keccak256(
  "\x19\x01",           // EIP-712 magic prefix (EIP‑191 version + structured data flag)
  domainSeparator,      // where we are
  structHash            // what we’re signing
)
This digest is what you actually sign with your private key.

Step 6: Sign It
text
(v, r, s) = sign(digest, privateKey)
You get back three numbers that prove you signed it.

Step 7: Verify On Chain
The contract receives v, r, s and does:

text
signer = ecrecover(digest, v, r, s)
require(signer == expectedAuthority, "Invalid signature!")
This magically recovers your address from the signature.

If it matches the address that should be authorizing the action, you signed it.

Heads-up: The signer isn’t always msg.sender. Often the contract stores a nonce or checks a mapping to see who’s allowed to sign. That’s why you’ll see require(signer == owner) or require(nonceUsed[nonce] == false). The msg.sender could be a relayer—someone else paying gas for you.

Done.

Why This is Brilliant
You Can See What You’re Signing
Before EIP-712, wallets would show:

text
Sign this transaction?
Data: 0x1234567890abcdef...
Meaningless gibberish.

With EIP-712, wallets show:

text
Sign this transaction?
Agent: 0x1234...
Permissions: 0xfff...
Expiry: Tuesday, Jan 1, 2025
Nonce: 5
Max Calls: 100
Bounty: 1 ETH
You can actually read it.
(Again, only if the dapp sends the struct to your wallet. But when it does, chefs kiss.)

It Can’t Be Replayed
If you sign a permit on Ethereum mainnet, someone can’t take that same signature and use it on Arbitrum or Optimism. The domainSeparator—which includes the chain ID and the contract address—prevents it.

It’s Standardized
Every wallet implements EIP-712 the same way. MetaMask, Ledger, Gnosis Safe, all of them. It’s a universal standard.

It Proves Intent
When you sign with EIP-712, you’re proving you understood exactly what you were signing. No ambiguity. No “I didn’t read the fine print.”

Real Example: GhostOperator
When you authorize an agent in GhostOperator, you’re signing:

text
AgentPermit {
  agent: BobTheRobot (0x5678...)
  permissions: 0xfff... (can swap tokens only)
  expiry: 1704067200 (next Tuesday)
  nonce: 5 (this is your 5th authorization)
  maxCalls: 100 (Bob can do this 100 times)
  bounty: 1 ETH (you pay Bob 1 ETH per task — but careful: bounty is in wei, so 1 ETH = 1e18 wei)
}
You sign this with MetaMask. MetaMask shows you all these fields. You click “sign.”

Now the contract has your signature. It verifies:

✅ Is this really your signature? (ecrecover)

✅ Is this for THIS contract on THIS chain? (domainSeparator)

✅ Is this the right struct definition? (typehash)

✅ Have you authorized Bob? (struct matches your intent)

All checks pass. Bob gets his permissions.

How to Use EIP-712 (Quick Reference)
For Users (You’re Signing)
See what you’re signing (if the dapp is nice)

Click “sign” in your wallet

Done. Your signature proves intent.

For Developers (Writing Contracts)
Define your struct

Store the typehash as a constant in the contract (so you can compute structHash on-chain)

Compute structHash from the incoming parameters

Compute digest = keccak256("\x19\x01", DOMAIN_SEPARATOR, structHash)

Use ecrecover to get the signer

Verify the signer is the authority (maybe not msg.sender!), and check the nonce hasn’t been used

solidity
// Pseudo-code (not real Solidity)
function permit(
  address agent,
  bytes32 permissions,
  uint256 expiry,
  uint256 nonce,
  uint256 maxCalls,
  uint256 bounty,
  uint8 v, bytes32 r, bytes32 s
) public {
  bytes32 structHash = keccak256(abi.encode(
    TYPEHASH,
    agent,
    permissions,
    expiry,
    nonce,
    maxCalls,
    bounty
  ));
  
  bytes32 digest = keccak256(abi.encodePacked(
    "\x19\x01",
    DOMAIN_SEPARATOR,
    structHash
  ));
  
  address signer = ecrecover(digest, v, r, s);
  require(signer == expectedAuthority, "Invalid signature!");
  require(!usedNonces[nonce], "Nonce already used");
  usedNonces[nonce] = true;
  
  // Do the thing
}
The Magic Explained (Sort Of)
The "\x19\x01" prefix is EIP-191’s way of saying “this is a structured signed message, not a transaction.”

The domainSeparator ties it to THIS specific contract, so:

Different contract = different hash = signature doesn’t work = replay prevented

Different chain = different chainId = signature doesn’t work = cross-chain replay prevented

The typehash ties it to THIS specific struct definition, so:

Someone changes the struct = typehash changes = signature doesn’t work = tampering detected

Everything is tamper-proof because changing ANYTHING changes the hash.

Why EIP-712 Rocks
✅ You can see what you’re signing (if the dapp helps)
✅ Replay protection (chain-specific, contract-specific)
✅ Standardized across all wallets
✅ Mathematically proven to be secure
✅ Gas-efficient (you pass the data in the call instead of storing it all on-chain — though you’ll still need to store nonces to prevent replays)

)
