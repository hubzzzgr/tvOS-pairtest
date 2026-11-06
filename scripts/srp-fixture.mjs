// Independent SRP-6a fixture using Node's SHA-512 and native BigInt, RFC 5054 group.
// This is synthetic test material, never a real device credential.
import fs from 'node:fs';
import { createHash } from 'node:crypto';
const source = fs.readFileSync('Packages/TVPairCore/Sources/TVPairCore/PairingCrypto.swift', 'utf8');
const primeHex = source.match(/static let prime = BigUInt\("""([\s\S]*?)"""/)[1].replace(/[\s\\]/g, '');
const N = BigInt(`0x${primeHex}`), g = 5n;
const bytes = n => { let hex = n.toString(16); if (hex.length % 2) hex = `0${hex}`; return Buffer.from(hex, 'hex'); };
const pad = n => Buffer.concat([Buffer.alloc(384 - bytes(n).length), bytes(n)]);
const hash = (...parts) => createHash('sha512').update(Buffer.concat(parts)).digest();
const integer = b => BigInt(`0x${b.toString('hex')}`);
const power = (a, b) => { let r = 1n; for (a %= N; b; b >>= 1n, a = a * a % N) if (b & 1n) r = r * a % N; return r; };
const aBytes = Buffer.from(Array.from({length:128}, (_,i) => i + 1));
const a = integer(aBytes), b = integer(Buffer.from(Array.from({length:128}, (_,i) => 128 - i)));
const salt = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
const x = integer(hash(salt, hash(Buffer.from('Pair-Setup:123456'))));
const k = integer(hash(bytes(N), pad(g))), v = power(g, x);
const A = power(g, a), B = (k * v + power(g, b)) % N;
const u = integer(hash(pad(A), pad(B)));
const clientShared = power((B - k * v % N + N) % N, a + u * x);
const serverShared = power(A * power(v, u), b);
if (clientShared !== serverShared || bytes(N).length !== 384) throw new Error('Invalid independent fixture');
const key = hash(bytes(serverShared));
const groupHash = integer(hash(bytes(N))) ^ integer(hash(bytes(g)));
const proof = hash(bytes(groupHash), bytes(integer(hash(Buffer.from('Pair-Setup')))), salt, bytes(A), bytes(B), key);
const serverProof = hash(bytes(A), proof, key);
const fixture = Object.fromEntries(Object.entries({privateKey:aBytes,salt,serverPublic:bytes(B),publicKey:bytes(A),key,proof,serverProof}).map(([k,v]) => [k,v.toString('hex')]));
fs.writeFileSync('Packages/TVPairCore/Tests/TVPairCoreTests/Fixtures/srp.json', JSON.stringify(fixture, null, 2) + '\n');
console.log('Generated independently cross-checked SRP client/server fixture.');
