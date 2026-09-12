import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const PRODUCTION_ORIGIN = "https://seedcoop.github.io";
const LOCAL_ORIGIN = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;
const EVENT_SLUG = "national-youth-volunteer-2026";
const TOKEN_AUDIENCE = "kb-volunteer-profile";
const TOKEN_VERSION = 1;
const VERSION_CONFIG = {
  "kb-vfi-education-2026-v1": {
    noticeVersion: "2026-09-12-v1",
    unsureAsZero: false,
  },
  "kb-vfi-education-2026-v2": {
    noticeVersion: "2026-09-12-v2",
    unsureAsZero: true,
  },
} as const;
const MAX_BODY_BYTES = 64 * 1024;
const encoder = new TextEncoder();

const FACTOR_QUESTIONS = {
  P: [7, 9, 11, 20, 24],
  V: [3, 8, 16, 19, 22],
  C: [1, 10, 15, 21, 28],
  S: [2, 4, 6, 17, 23],
  U: [12, 14, 18, 25, 30],
  E: [5, 13, 26, 27, 29],
} as const;

type FactorKey = keyof typeof FACTOR_QUESTIONS;
type Answer = 1 | 2 | 3 | 4 | 5 | "unsure";
type Scores = Record<FactorKey, number | null>;
type Ranks = Record<FactorKey, number | null>;

interface TokenPayload {
  aud: typeof TOKEN_AUDIENCE;
  eventSlug: string;
  exp: number;
  iat: number;
  jti: string;
  v: typeof TOKEN_VERSION;
}

class HttpError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

function isAllowedOrigin(origin: string | null): boolean {
  return origin === null || origin === PRODUCTION_ORIGIN || LOCAL_ORIGIN.test(origin);
}

function responseHeaders(origin: string | null): HeadersInit {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Vary": "Origin",
    "X-Content-Type-Options": "nosniff",
  };

  if (origin && isAllowedOrigin(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }

  return headers;
}

function jsonResponse(
  origin: string | null,
  status: number,
  body: Record<string, unknown>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders(origin),
  });
}

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function adminSecretKey(): string {
  const namedKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (namedKeys) {
    try {
      const parsed = JSON.parse(namedKeys) as Record<string, unknown>;
      if (typeof parsed.default === "string" && parsed.default.length > 0) {
        return parsed.default;
      }
    } catch {
      // Older/local runtimes may not provide the named secret-key dictionary.
    }
  }
  return requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
}

function encodeBase64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

function decodeBase64Url(value: string): ArrayBuffer {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }

  const standard = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = standard + "=".repeat((4 - (standard.length % 4)) % 4);

  try {
    return Uint8Array.from(
      atob(padded),
      (character) => character.charCodeAt(0),
    ).buffer;
  } catch {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function signingKey(): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    encoder.encode(adminSecretKey()),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

async function signToken(payload: TokenPayload): Promise<string> {
  const encodedPayload = encodeBase64Url(
    encoder.encode(JSON.stringify(payload)),
  );
  const message = encoder.encode(`${TOKEN_AUDIENCE}.${encodedPayload}`);
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", await signingKey(), message),
  );
  return `${encodedPayload}.${encodeBase64Url(signature)}`;
}

async function verifyToken(token: string): Promise<TokenPayload> {
  const parts = token.split(".");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }

  const message = encoder.encode(`${TOKEN_AUDIENCE}.${parts[0]}`);
  const isValid = await crypto.subtle.verify(
    "HMAC",
    await signingKey(),
    decodeBase64Url(parts[1]),
    message,
  );

  if (!isValid) {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }

  let payload: TokenPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(decodeBase64Url(parts[0])));
  } catch {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }

  const now = Math.floor(Date.now() / 1000);
  if (
    !payload ||
    payload.aud !== TOKEN_AUDIENCE ||
    payload.v !== TOKEN_VERSION ||
    payload.eventSlug !== EVENT_SLUG ||
    typeof payload.iat !== "number" ||
    typeof payload.exp !== "number" ||
    typeof payload.jti !== "string" ||
    payload.iat > now + 60 ||
    payload.exp > payload.iat + 12 * 60 * 60
  ) {
    throw new HttpError(401, "TOKEN_INVALID", "활성화 정보를 다시 확인해 주세요.");
  }

  if (payload.exp <= now) {
    throw new HttpError(401, "TOKEN_EXPIRED", "활성화 시간이 지났어요. 코드를 다시 입력해 주세요.");
  }

  return payload;
}

function readBearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization) return null;
  const match = /^Bearer\s+(.+)$/iu.exec(authorization.trim());
  return match?.[1] ?? null;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "INVALID_REQUEST", "요청 내용을 확인해 주세요.");
  }
  return value as Record<string, unknown>;
}

function normalizeText(
  value: unknown,
  field: "이름" | "학교 또는 소속",
  maximumLength: number,
): string {
  if (typeof value !== "string") {
    throw new HttpError(400, "INVALID_PARTICIPANT", `${field}을(를) 입력해 주세요.`);
  }

  const normalized = value.trim().replace(/\s+/gu, " ");
  const length = Array.from(normalized).length;
  if (length < 1 || length > maximumLength) {
    throw new HttpError(
      400,
      "INVALID_PARTICIPANT",
      `${field}은(는) ${maximumLength}자 이내로 입력해 주세요.`,
    );
  }
  return normalized;
}

function validateVersionPair(
  instrumentValue: unknown,
  noticeValue: unknown,
): {
  instrumentVersion: keyof typeof VERSION_CONFIG;
  noticeVersion: string;
  unsureAsZero: boolean;
} {
  if (
    typeof instrumentValue !== "string" ||
    !Object.prototype.hasOwnProperty.call(VERSION_CONFIG, instrumentValue)
  ) {
    throw new HttpError(400, "INVALID_VERSION", "검사 버전을 확인해 주세요.");
  }

  const instrumentVersion = instrumentValue as keyof typeof VERSION_CONFIG;
  const config = VERSION_CONFIG[instrumentVersion];
  if (noticeValue !== config.noticeVersion) {
    throw new HttpError(400, "INVALID_VERSION", "수집 안내 버전을 확인해 주세요.");
  }

  return {
    instrumentVersion,
    noticeVersion: config.noticeVersion,
    unsureAsZero: config.unsureAsZero,
  };
}

function validateSubmissionId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value)
  ) {
    throw new HttpError(400, "INVALID_SUBMISSION_ID", "제출 식별자를 다시 만들어 주세요.");
  }
  return value.toLowerCase();
}

function validateAnswers(value: unknown): Answer[] {
  if (
    !Array.isArray(value) ||
    value.length !== 30 ||
    !value.every((answer) =>
      answer === "unsure" ||
      (Number.isInteger(answer) && Number(answer) >= 1 && Number(answer) <= 5)
    )
  ) {
    throw new HttpError(400, "INVALID_ANSWERS", "30개 문항의 응답을 확인해 주세요.");
  }
  return value as Answer[];
}

function calculateResults(answers: Answer[], unsureAsZero: boolean): {
  scores: Scores;
  ranks: Ranks;
  unknownCount: number;
} {
  const scores = {} as Scores;
  const sums = {} as Record<FactorKey, number | null>;

  for (const key of Object.keys(FACTOR_QUESTIONS) as FactorKey[]) {
    const values = FACTOR_QUESTIONS[key].map((questionNumber) =>
      answers[questionNumber - 1]
    );
    if (!unsureAsZero && values.some((answer) => answer === "unsure")) {
      sums[key] = null;
      scores[key] = null;
      continue;
    }
    const sum = values.reduce<number>(
      (total, answer) => total + (answer === "unsure" ? 0 : answer),
      0,
    );
    sums[key] = sum;
    scores[key] = sum / 5;
  }

  const isComplete = Object.values(sums).every((sum) => sum !== null);
  const ranks = {} as Ranks;
  for (const key of Object.keys(FACTOR_QUESTIONS) as FactorKey[]) {
    const sum = sums[key];
    ranks[key] = isComplete && sum !== null
      ? 1 + Object.values(sums).filter((other) => other !== null && other > sum).length
      : null;
  }

  return {
    scores,
    ranks,
    unknownCount: answers.filter((answer) => answer === "unsure").length,
  };
}

async function parseBody(request: Request): Promise<Record<string, unknown>> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new HttpError(413, "REQUEST_TOO_LARGE", "요청 내용이 너무 커요.");
  }

  const text = await request.text();
  if (encoder.encode(text).byteLength > MAX_BODY_BYTES) {
    throw new HttpError(413, "REQUEST_TOO_LARGE", "요청 내용이 너무 커요.");
  }

  try {
    return asRecord(JSON.parse(text));
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "INVALID_JSON", "요청 내용을 읽지 못했어요.");
  }
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");

  if (request.method === "OPTIONS") {
    if (!isAllowedOrigin(origin)) {
      return jsonResponse(origin, 403, {
        ok: false,
        error: "ORIGIN_NOT_ALLOWED",
        message: "허용되지 않은 접속 경로예요.",
      });
    }
    return new Response(null, { status: 204, headers: responseHeaders(origin) });
  }

  if (!isAllowedOrigin(origin)) {
    return jsonResponse(origin, 403, {
      ok: false,
      error: "ORIGIN_NOT_ALLOWED",
      message: "허용되지 않은 접속 경로예요.",
    });
  }

  if (request.method !== "POST") {
    return jsonResponse(origin, 405, {
      ok: false,
      error: "METHOD_NOT_ALLOWED",
      message: "POST 요청만 사용할 수 있어요.",
    });
  }

  try {
    const body = await parseBody(request);
    const action = body.action;
    if (action !== "activate" && action !== "submit") {
      throw new HttpError(400, "INVALID_ACTION", "요청 종류를 확인해 주세요.");
    }

    const supabase = createClient(
      requiredEnvironment("SUPABASE_URL"),
      adminSecretKey(),
      {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { "X-Client-Info": "kb-volunteer-profile-edge/1" } },
      },
    );

    if (action === "activate") {
      if (typeof body.code !== "string" || body.code.length > 32) {
        throw new HttpError(401, "INVALID_ACTIVATION_CODE", "활성화 코드를 확인해 주세요.");
      }

      const normalizedCode = body.code.trim().toUpperCase();
      const codeHash = await sha256Hex(normalizedCode);
      const { data: event, error } = await supabase
        .from("volunteer_events")
        .select("event_slug, token_ttl_minutes")
        .eq("event_slug", EVENT_SLUG)
        .eq("activation_code_hash", codeHash)
        .eq("is_active", true)
        .maybeSingle();

      if (error) throw new Error("Could not read event configuration");
      if (!event) {
        throw new HttpError(401, "INVALID_ACTIVATION_CODE", "활성화 코드를 확인해 주세요.");
      }

      const issuedAt = Math.floor(Date.now() / 1000);
      const ttlMinutes = Math.min(720, Math.max(60, Number(event.token_ttl_minutes)));
      const expiresAt = issuedAt + ttlMinutes * 60;
      const token = await signToken({
        aud: TOKEN_AUDIENCE,
        eventSlug: event.event_slug,
        exp: expiresAt,
        iat: issuedAt,
        jti: crypto.randomUUID(),
        v: TOKEN_VERSION,
      });

      return jsonResponse(origin, 200, {
        ok: true,
        token,
        expiresAt: new Date(expiresAt * 1000).toISOString(),
        eventSlug: event.event_slug,
      });
    }

    const token = typeof body.token === "string" ? body.token : readBearerToken(request);
    if (!token) {
      throw new HttpError(401, "TOKEN_REQUIRED", "활성화 코드를 먼저 입력해 주세요.");
    }
    const tokenPayload = await verifyToken(token);

    const { data: event, error: eventError } = await supabase
      .from("volunteer_events")
      .select("is_active")
      .eq("event_slug", tokenPayload.eventSlug)
      .maybeSingle();
    if (eventError) throw new Error("Could not verify event state");
    if (!event?.is_active) {
      throw new HttpError(403, "EVENT_INACTIVE", "현재는 결과를 제출할 수 없어요.");
    }

    const participant = asRecord(body.participant);
    const participantName = normalizeText(participant.name, "이름", 40);
    const affiliation = normalizeText(participant.affiliation, "학교 또는 소속", 80);
    const submissionId = validateSubmissionId(body.submissionId);
    const answers = validateAnswers(body.answers);
    const versions = validateVersionPair(
      body.instrumentVersion,
      body.noticeVersion,
    );
    const results = calculateResults(answers, versions.unsureAsZero);

    const { data, error } = await supabase.rpc("upsert_volunteer_submission", {
      p_submission_id: submissionId,
      p_event_slug: tokenPayload.eventSlug,
      p_participant_name: participantName,
      p_affiliation: affiliation,
      p_answers: answers,
      p_scores: results.scores,
      p_ranks: results.ranks,
      p_unknown_count: results.unknownCount,
      p_instrument_version: versions.instrumentVersion,
      p_notice_version: versions.noticeVersion,
    });

    if (error || !Array.isArray(data) || !data[0]) {
      throw new Error("Could not save submission");
    }

    return jsonResponse(origin, 200, {
      ok: true,
      submissionId: data[0].submission_id,
      savedAt: data[0].saved_at,
      scores: results.scores,
      ranks: results.ranks,
      revision: data[0].revision,
    });
  } catch (error) {
    if (error instanceof HttpError) {
      return jsonResponse(origin, error.status, {
        ok: false,
        error: error.code,
        message: error.message,
      });
    }

    return jsonResponse(origin, 500, {
      ok: false,
      error: "SERVER_ERROR",
      message: "잠시 후 다시 시도해 주세요.",
    });
  }
});
