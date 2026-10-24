/**
 * CcCrypto —— 云课堂（智教云）签名体系加密工具
 *
 * 依据抓包记录《云课堂接入抓包记录.md》逆向出的签名算法：
 *  - validCode = md5( 参数串 + "&signKey=123123" )
 *  - x-Nonce   = md5( userId + x-Time + uuid4 )
 *  - x-Sign    = md5( x-Nonce + x-Time + "njlz@123" )
 *  - x-Token   = DES-CBC-Pkcs7-Decrypt( sessionId_hex, key="njlz@123", iv="njlz@123" )
 *
 * 说明：HarmonyOS cryptoFramework 仅提供 3DES（DES-EDE3-CBC），不提供单 DES。
 * 当 3DES 的三个 8 字节子密钥相同（K1=K2=K3）时，数学上等价于单 DES
 * （E(K,D(K,E(K,P)))=E(K,P) / D(K,E(K,D(K,C)))=D(K,C)），
 * 故将 8 字节 desKey 重复 3 次拼成 24 字节 key，用 DES-EDE3-CBC 实现单 DES 解密。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/** 云课堂签名密钥（前端 staticConfig 硬编码） */
export const CC_SIGN_KEY: string = '123123';
export const CC_CLIENT_KEY: string = 'njlz@123';
export const CC_DES_KEY: string = 'njlz@123';   // 8 字节
export const CC_DES_IV: string = 'njlz@123';    // 8 字节
/** 云课堂 localStorage 包装层的 AES-128 密钥（前端硬编码，抓包实测） */
export const CC_LS_AES_KEY: string = 'mysupersecret123';

/**
 * 计算字符串的 MD5（小写 hex）。
 * 用 cryptoFramework createMd('MD5')，与前端 md5() 输出一致。
 */
export async function ccMd5(input: string): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
  const bytes: Uint8Array = stringToUtf8(input);
  md.updateSync({ data: bytes });
  const digest: cryptoFramework.DataBlob = md.digestSync();
  return bytesToHex(digest.data);
}

/**
 * 生成 validCode（query 签名）：md5( "<k1>=<v1>&<k2>=<v2>&signKey=123123" )。
 * pairs 为业务参数（不含 signKey），如 { courseId: 'xxx' } → md5("courseId=xxx&signKey=123123")。
 * 空 pairs 即默认签名 md5("&signKey=123123")。
 */
export async function ccValidCode(pairs: Record<string, string> | undefined): Promise<string> {
  const keys: string[] = pairs === undefined ? [] : Object.keys(pairs);
  const parts: string[] = [];
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    const v: string = pairs === undefined ? '' : (pairs[k] ?? '');
    parts.push(`${k}=${v}`);
  }
  const raw: string = parts.length > 0 ? `${parts.join('&')}&signKey=${CC_SIGN_KEY}` : `&signKey=${CC_SIGN_KEY}`;
  return ccMd5(raw);
}

/**
 * 生成无业务参数的 validCode（默认签名）。
 */
export async function ccValidCodeEmpty(): Promise<string> {
  return ccValidCode(undefined);
}

/**
 * 生成带单个 id 参数的 validCode：md5("id=<id>&signKey=123123")。
 */
export async function ccValidCodeWithId(id: string): Promise<string> {
  return ccMd5(`id=${id}&signKey=${CC_SIGN_KEY}`);
}

/**
 * AES-128-ECB-Pkcs7 解密（解云课堂 localStorage 包装层）。
 *
 * 依据抓包实测（云课堂WebView接管抓包记录 v2 发现 2）：localStorage 各 key 均为
 * `{"data":"<base64>","time":<ms>}`，其中 data 用前端 CryptoJS
 * `AES.encrypt(utf8, "mysupersecret123", {mode:ECB, padding:Pkcs7})` 加密。
 * 解出的明文是 80 位 hex，再用 ccDesDecrypt 解出 x-Token（UUID）。
 *
 * @param b64Cipher localStorage[...].data 的 base64 密文
 * @param keyText 固定 "mysupersecret123"（16 字节）
 */
export async function ccAesEcbDecrypt(b64Cipher: string, keyText: string = CC_LS_AES_KEY): Promise<string> {
  const ct: Uint8Array = base64ToBytes(b64Cipher);
  if (ct.length === 0 || ct.length % 16 !== 0) {
    throw new Error(`密文长度非法（${ct.length} 字节）`);
  }
  const keyBytes: Uint8Array = stringToUtf8(keyText);
  const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: keyBytes });
  // ⚠ 设备侧 createCipher('AES128|ECB|PKCS7') 直接报 "create C cipher fail"（OpenSSL 后端未编入 ECB）。
  //   等价变换：ECB 解密 ≡ 每个 16 字节块独立做 CBC 解密且 IV 全零
  //   （CBC 定义 P = D(C) XOR IV，IV=0 时 P = D(C)，与 ECB 单块结果完全一致）。
  //   故按块切分，逐块 AES128|CBC|NoPadding + 零 IV 解密，最后手工去 PKCS7 填充。
  const zeroIv: Uint8Array = new Uint8Array(16);
  const ivParams: cryptoFramework.IvParamsSpec = {
    iv: { data: zeroIv },
    algName: 'IvParamsSpec'
  };
  const plain: Uint8Array = new Uint8Array(ct.length);
  for (let off = 0; off < ct.length; off += 16) {
    const block: Uint8Array = ct.slice(off, off + 16);
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivParams);
    const dec: cryptoFramework.DataBlob = cipher.doFinalSync({ data: block });
    if (dec.data.length !== 16) {
      throw new Error(`分块解密长度异常（${dec.data.length}）`);
    }
    plain.set(dec.data, off);
  }
  // 手工去 PKCS7 填充（末字节 n：末尾 n 个字节都等于 n 才裁掉）
  const pad: number = plain[plain.length - 1];
  let end: number = plain.length;
  if (pad >= 1 && pad <= 16 && pad <= plain.length) {
    let ok: boolean = true;
    for (let i = plain.length - pad; i < plain.length; i++) {
      if (plain[i] !== pad) {
        ok = false;
        break;
      }
    }
    if (ok) {
      end = plain.length - pad;
    }
  }
  return utf8ToString(plain.slice(0, end));
}

/**
 * 解 localStorage 里的一项：base64 → AES-128-ECB → 明文。
 * 兼容两种入参：
 *  ① localStorage 原值 JSON：`{"data":"<base64>","time":...}`（页面脚本可能直接返回原值）
 *  ② 已提取的 data base64 原文（WebView 侧已 JSON.parse 过时就是这种，128 字符）
 */
export async function ccDecodeLsValue(raw: string): Promise<string> {
  if (raw.length === 0) {
    return '';
  }
  let data: string = raw;
  // 仅当看起来是 JSON 对象时才解析，否则视为已提取的 base64 原文
  if (raw.trim().startsWith('{')) {
    try {
      const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      data = String(obj['data'] ?? '');
    } catch (e) {
      data = raw;
    }
  }
  if (data.length === 0) {
    return '';
  }
  return await ccAesEcbDecrypt(data);
}

/** base64 → 字节数组 */
function base64ToBytes(b64: string): Uint8Array {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.decodeSync(b64);
}

/**
 * DES-CBC-Pkcs7 解密（等价单 DES，经 DES-EDE3-CBC 实现）。
 * @param hexCipher 密文 hex（如 sessionId 的 96 hex）
 * @returns 明文 UTF-8 字符串（如 x-Token UUID）
 */
export async function ccDesDecrypt(hexCipher: string): Promise<string> {
  const cipherBytes: Uint8Array = hexToBytes(hexCipher);
  // 单 DES → 3DES 等价：8 字节 key 重复 3 次成 24 字节
  const key24: Uint8Array = new Uint8Array(24);
  for (let i = 0; i < 24; i++) {
    key24[i] = CC_DES_KEY.charCodeAt(i % 8) & 0xff;
  }
  const iv8: Uint8Array = new Uint8Array(8);
  for (let i = 0; i < 8; i++) {
    iv8[i] = CC_DES_IV.charCodeAt(i) & 0xff;
  }
  const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('3DES192');
  const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: key24 });
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('DES-EDE3-CBC|PKCS7');
  const ivParams: cryptoFramework.IvParamsSpec = {
    iv: { data: iv8 },
    algName: 'IvParamsSpec'
  };
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivParams);
  const decrypted: cryptoFramework.DataBlob = cipher.doFinalSync({ data: cipherBytes });
  return utf8ToString(decrypted.data);
}

/**
 * 生成签名请求头四件套（x-Token/x-Nonce/x-Sign/x-Time），外加 Referer/X-Requested-With。
 * @param userId 云课堂 userId（ff8081...）
 * @param xToken DES 解密后的 UUID（x-Token）
 * @param referer 固定 https://zjy.njmu.edu.cn/TeachingCenterStudentWeb/index.html
 */
export async function ccSignHeaders(userId: string, xToken: string, referer: string): Promise<Record<string, string>> {
  const t: string = `${Date.now()}`;
  const nonce: string = await ccMd5(`${userId}${t}${ccUuid()}`);
  const sign: string = await ccMd5(`${nonce}${t}${CC_CLIENT_KEY}`);
  const h: Record<string, string> = {};
  h['x-Token'] = xToken;
  h['x-Nonce'] = nonce;
  h['x-Sign'] = sign;
  h['x-Time'] = t;
  h['X-Requested-With'] = 'xmlhttprequest';
  h['Referer'] = referer;
  h['Content-Type'] = 'application/json';
  return h;
}

/** 生成 UUID v4（x-Nonce 计算用，无连字符或带连字符均可，前端用无连字符） */
export function ccUuid(): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < 32; i++) {
    out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return out;
}

// ── 内部工具 ──

function stringToUtf8(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xff;
  }
  return out;
}

function utf8ToString(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += hex.charAt((bytes[i] >> 4) & 0x0f);
    out += hex.charAt(bytes[i] & 0x0f);
  }
  return out;
}

function hexToBytes(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}
