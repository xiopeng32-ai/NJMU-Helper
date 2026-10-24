/**
 * 无 UI 进程下的会话恢复（供 WorkScheduler 后台任务使用）
 *
 * 这是 `pages/Index.ets` 冷启动恢复逻辑的**复刻**（不是重构）：
 *  Index 的那段是登录态最敏感的部分，不做改动，新功能用独立实现，
 *  失败时只返回 false，绝不抛异常打断后台任务。
 *
 * 三条路径（与 Index 一致）：
 *  1) 网页登录：直接复用持久化的 jwglxt 会话 Cookie；
 *  2) 统一认证：用 CASTGC 静默桥接换新会话；
 *  3) 教务 RSA：用保存的账号密码直登。
 */
import { DataStore } from './DataStore';
import { LogStore } from './LogStore';
import { JwApi } from '../api/JwApi';
import { HttpClient } from '../api/HttpClient';
import { DateUtil } from './DateUtil';
import { TermInfo } from '../model/Models';

export class SessionRestorer {
  /** 恢复学期（与 Index 相同的选择顺序：用户上次选择 → 当前日期推算） */
  static restoreTerm(): void {
    try {
      const termId: string = DataStore.get(DataStore.KEY_DS_TERM);
      const terms: TermInfo[] = JwApi.buildLocalTerms();
      let picked: TermInfo | null = null;
      for (const t of terms) {
        if (t.id === termId) {
          picked = t;
          break;
        }
      }
      JwApi.setTerm(picked !== null ? picked : DateUtil.buildCurrentTerm());
    } catch (e) {
      LogStore.log('后台', '恢复学期', '失败', LogStore.errorOf(e as Object));
    }
  }

  /** 恢复会话；返回是否可用。总共不超过 timeoutMs */
  static async restoreSession(timeoutMs: number = 45000): Promise<boolean> {
    try {
      const cookie: string = DataStore.get(DataStore.KEY_SESSION_COOKIE);
      const loginMethod: string = DataStore.getLoginMethod();
      const loginSystem: string = DataStore.get(DataStore.KEY_LOGIN_SYSTEM);
      const casTgc: string = DataStore.get(DataStore.KEY_CAS_TGC);
      const autoAcct: string = DataStore.get(DataStore.KEY_AUTO_ACCOUNT);
      const autoPwd: string = DataStore.get(DataStore.KEY_AUTO_PWD);

      // 1) 网页登录：直接用持久化会话
      if (loginMethod === 'web' && cookie.length > 0) {
        HttpClient.setCookie(cookie);
        LogStore.log('后台', '恢复会话', '网页会话', '复用本地 Cookie');
        return true;
      }
      // 2) 统一认证：CASTGC 静默桥接
      if ((loginMethod === 'web' || loginSystem === 'service') && casTgc.length > 0) {
        const ok: boolean = await SessionRestorer.withTimeout(JwApi.silentCasRelogin(), timeoutMs, false);
        LogStore.log('后台', '恢复会话', ok ? 'CASTGC桥接成功' : 'CASTGC桥接失败', '');
        return ok;
      }
      // 3) 教务 RSA 直登
      if (autoAcct.length > 0 && autoPwd.length > 0) {
        const ok: boolean = await SessionRestorer.withTimeout(
          JwApi.login(autoAcct, DataStore.decodePwd(autoPwd), '', 'original').then(() => true).catch(() => false),
          timeoutMs, false);
        LogStore.log('后台', '恢复会话', ok ? '账号直登成功' : '账号直登失败', '');
        return ok;
      }
      // 4) 兜底：本地 Cookie（可能已过期，靠后续请求失败暴露）
      if (cookie.length > 0) {
        HttpClient.setCookie(cookie);
        return true;
      }
      LogStore.log('后台', '恢复会话', '无可用凭据', '');
      return false;
    } catch (e) {
      LogStore.log('后台', '恢复会话', '异常', LogStore.errorOf(e as Object));
      return false;
    }
  }

  /** 给 Promise 加超时（后台任务有 2 分钟硬上限，必须能主动放弃） */
  static async withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
    let timer: number = -1;
    const timeout: Promise<T> = new Promise<T>((resolve: (v: T) => void) => {
      timer = setTimeout(() => {
        resolve(fallback);
      }, ms);
    });
    try {
      return await Promise.race([p, timeout]);
    } finally {
      if (timer > 0) {
        clearTimeout(timer);
      }
    }
  }
}
