/**
 * 백엔드 주소.
 *
 * VITE_BACKEND_URL 을 명시하면 그 값을 쓰고, 없으면 "지금 UI 를 열고 있는
 * 호스트"의 백엔드 포트를 가리킨다. localhost 로 고정해 두면, 다른 PC 에서
 * 접속했을 때 브라우저가 그 PC 자신의 localhost 를 찾아가 실패한다.
 */
const BACKEND_PORT = import.meta.env.VITE_BACKEND_PORT ?? "8080";

function resolveBaseUrl(): string {
  const explicit = import.meta.env.VITE_BACKEND_URL;
  if (explicit) return explicit;
  if (typeof window !== "undefined" && window.location?.hostname) {
    return `${window.location.protocol}//${window.location.hostname}:${BACKEND_PORT}`;
  }
  return `http://localhost:${BACKEND_PORT}`;
}

const BASE_URL = resolveBaseUrl();

export type RecordType = "A" | "CNAME";

export interface DNSRecord {
  id: number;
  domain: string;
  record_type: RecordType;
  value: string;
  ttl: number;
  enabled: boolean;
  created_at: string;
  updated_at: string;
}

export interface AuditLog {
  id: number;
  timestamp: string;
  action: string;
  record_id: number | null;
  domain: string;
  record_type: string;
  value: string;
  detail: string | null;
}

export interface ForwardingConfig {
  upstreams: string[];
}

export interface SyncStatus {
  zone_serial: number | null;
  served_serial: number | null;
  in_sync: boolean;
  dns_reachable: boolean;
  detail: string | null;
}

export interface QueryAnswer {
  name: string;
  type: string;
  ttl: number;
  data: string;
}

export interface QueryResult {
  domain: string;
  record_type: string;
  status: string;
  query_time_ms: number;
  answers: QueryAnswer[];
}

export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * FastAPI 의 에러 본문을 사람이 읽을 수 있는 한 줄로 바꾼다.
 * 422(검증 실패)는 detail 이 객체 배열이라 그대로 출력하면 raw JSON 이 노출된다.
 */
async function extractErrorMessage(res: Response): Promise<string> {
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return `HTTP ${res.status}`;
  }

  const detail = (body as { detail?: unknown })?.detail;
  if (typeof detail === "string") return detail;

  if (Array.isArray(detail)) {
    const messages = detail
      .map((item) => {
        const entry = item as { msg?: unknown; loc?: unknown };
        const msg = typeof entry.msg === "string" ? entry.msg.replace(/^Value error, /, "") : null;
        if (!msg) return null;
        const loc = Array.isArray(entry.loc) ? entry.loc.filter((p) => p !== "body").join(".") : "";
        return loc ? `${loc}: ${msg}` : msg;
      })
      .filter((m): m is string => Boolean(m));
    if (messages.length > 0) return messages.join(" / ");
  }

  return `HTTP ${res.status}`;
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });

  if (!res.ok) {
    throw new Error(await extractErrorMessage(res));
  }

  if (res.status === 204) return undefined as T;
  return res.json();
}

export const api = {
  listRecords: () => request<DNSRecord[]>("/records"),

  createRecord: (data: { domain: string; record_type: RecordType; value: string; ttl: number }) =>
    request<DNSRecord>("/records", { method: "POST", body: JSON.stringify(data) }),

  updateRecord: (id: number, data: { value: string; ttl: number }) =>
    request<DNSRecord>(`/records/${id}`, { method: "PUT", body: JSON.stringify(data) }),

  deleteRecord: (id: number) => request<void>(`/records/${id}`, { method: "DELETE" }),

  setRecordEnabled: (id: number, enabled: boolean) =>
    request<DNSRecord>(`/records/${id}`, { method: "PATCH", body: JSON.stringify({ enabled }) }),

  listAuditLogs: () => request<AuditLog[]>("/audit-logs"),

  getSyncStatus: () => request<SyncStatus>("/sync-status"),

  getForwarding: () => request<ForwardingConfig>("/forwarding"),

  setForwarding: (upstreams: string[]) =>
    request<ForwardingConfig>("/forwarding", {
      method: "PUT",
      body: JSON.stringify({ upstreams }),
    }),

  queryTest: (domain: string, record_type: string) =>
    request<QueryResult>("/query-test", {
      method: "POST",
      body: JSON.stringify({ domain, record_type }),
    }),
};
