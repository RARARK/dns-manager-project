import { useCallback, useEffect, useRef, useState } from "react";
import { api, type SyncStatus } from "./api";

export type SyncPhase = "synced" | "pending" | "unreachable" | "unknown";

const IDLE_POLL_MS = 5000; // 평상시: 가볍게만 확인
const BUSY_POLL_MS = 300; // 변경 직후: 반영 시점을 촘촘히 잡는다
const PENDING_TIMEOUT_MS = 20000;

/**
 * 존 파일의 SOA serial 과 CoreDNS 가 실제로 응답하는 serial 을 비교해
 * "저장은 됐지만 DNS 에는 아직 반영되지 않은" 구간을 추적한다.
 *
 * 저장 직후 markChanged() 를 부르면 빠른 폴링으로 전환하고,
 * 반영이 확인되면 경과 시간과 함께 다시 느린 폴링으로 돌아간다.
 */
export function useDnsSync() {
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [phase, setPhase] = useState<SyncPhase>("unknown");
  const [elapsedMs, setElapsedMs] = useState(0);

  const phaseRef = useRef<SyncPhase>("unknown");
  // 저장 직후 즉시 한 번 확인하기 위한 훅. 폴링 effect 가 채운다.
  const kick = useRef<(() => void) | null>(null);
  const busyUntil = useRef<number>(0);
  const changedAt = useRef<number | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const tick = useRef<ReturnType<typeof setInterval> | null>(null);

  const markChanged = useCallback(() => {
    changedAt.current = Date.now();
    busyUntil.current = Date.now() + PENDING_TIMEOUT_MS;
    setPhase("pending");
    setElapsedMs(0);
    // busyUntil 만 세워두면 다음 폴링(최대 IDLE_POLL_MS)까지 기다리게 되어,
    // DNS 가 이미 반영됐는데도 배지가 몇 초 더 "반영 중"으로 남는다.
    kick.current?.();
  }, []);

  // 대기 중일 때만 경과 시간을 1/10초 단위로 센다
  // 폴링 콜백은 한 번만 만들어지므로, 최신 phase 는 ref 로 읽는다.
  useEffect(() => {
    phaseRef.current = phase;
  }, [phase]);

  useEffect(() => {
    if (phase === "pending" && changedAt.current !== null) {
      tick.current = setInterval(() => {
        if (changedAt.current !== null) setElapsedMs(Date.now() - changedAt.current);
      }, 100);
    }
    return () => {
      if (tick.current) clearInterval(tick.current);
      tick.current = null;
    };
  }, [phase]);

  useEffect(() => {
    let cancelled = false;

    const poll = async () => {
      let next = IDLE_POLL_MS;
      try {
        const s = await api.getSyncStatus();
        if (cancelled) return;
        setStatus(s);

        if (!s.dns_reachable) {
          setPhase("unreachable");
        } else if (s.in_sync) {
          if (phaseRef.current === "pending" && changedAt.current !== null) {
            setElapsedMs(Date.now() - changedAt.current);
            changedAt.current = null;
          }
          setPhase("synced");
          busyUntil.current = 0;
        } else {
          setPhase("pending");
          if (changedAt.current === null) changedAt.current = Date.now();
        }

        const busy = Date.now() < busyUntil.current || !s.in_sync;
        next = busy ? BUSY_POLL_MS : IDLE_POLL_MS;
      } catch {
        if (!cancelled) setPhase("unreachable");
      }
      if (!cancelled) timer.current = setTimeout(poll, next);
    };

    // 외부에서 즉시 폴링을 요청할 수 있게 한다.
    kick.current = () => {
      if (timer.current) clearTimeout(timer.current);
      void poll();
    };

    poll();
    return () => {
      cancelled = true;
      kick.current = null;
      if (timer.current) clearTimeout(timer.current);
    };
  }, []);

  return { status, phase, elapsedMs, markChanged };
}

/**
 * DNS 반영이 확인될 때까지 기다린다. 저장 토스트를 "반영 중" -> "반영 완료"로
 * 바꾸는 데 쓴다. 반환값은 반영까지 걸린 시간(ms), 시간 초과면 null.
 */
export async function waitForSync(timeoutMs = 20000): Promise<number | null> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const s = await api.getSyncStatus();
      if (s.in_sync) return Date.now() - started;
      if (!s.dns_reachable) return null;
    } catch {
      return null;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}
