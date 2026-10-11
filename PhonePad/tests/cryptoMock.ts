// Exercise the transport with standard AES-GCM without loading mobile native modules.
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

let gate: Promise<void> | undefined;
export function holdEncryption() {
  let release!: () => void;
  gate = new Promise<void>(resolve => { release = resolve; });
  return release;
}
export class AESEncryptionKey {
  constructor(public bytes: Buffer) {}
  static async import(value: string) { return new AESEncryptionKey(Buffer.from(value, 'base64')); }
}
export class AESSealedData {
  constructor(public bytes: Buffer) {}
  static fromCombined(value: Uint8Array) {
    // Android's native API accepts a typed byte array, even though Expo's
    // cross-platform TypeScript signature also permits a base64 string.
    if (!(value instanceof Uint8Array)) throw new TypeError('Expected Uint8Array');
    return new AESSealedData(Buffer.from(value));
  }
  async combined() { return this.bytes.toString('base64'); }
}
export async function aesEncryptAsync(plain: Uint8Array, key: AESEncryptionKey) {
  const wait = gate;
  gate = undefined;
  if (wait) await wait;
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key.bytes, nonce);
  return new AESSealedData(Buffer.concat([nonce, cipher.update(plain), cipher.final(), cipher.getAuthTag()]));
}
export async function aesDecryptAsync(sealed: AESSealedData, key: AESEncryptionKey) {
  const data = sealed.bytes;
  const decipher = createDecipheriv('aes-256-gcm', key.bytes, data.subarray(0, 12));
  decipher.setAuthTag(data.subarray(-16));
  return Buffer.concat([decipher.update(data.subarray(12, -16)), decipher.final()]);
}
