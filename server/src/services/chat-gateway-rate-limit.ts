/**
 * In-process sliding-window rate limiter for the `/api/chat/completions`
 * gateway.
 *
 * Why this exists:
 * - REVA-24565 review finding #6 noted that the chat gateway had no rate
 *   limiting — any actor that passed the auth gate could spawn unlimited
 *   codex runs.
 * - The intended caller is the false-done-guard judge running inside this
 *   same server (server/src/services/false-done-guard.ts), but the route
 *   is still reachable by any authenticated admin / canCreateAgents actor.
 *   This limiter is defense-in-depth: even if an admin key leaks, spam is
 *   contained to a small in-process budget.
 *
 * Defaults are intentionally conservative so the judge can still run
 * at normal throughput while a misbehaving caller is throttled within a
 * single 60s window. The limiter is injected so tests can override the
 * window and request ceiling.
 */
export const CHAT_GATEWAY_RATE_LIMIT_WINDOW_MS = 60_000;
export const CHAT_GATEWAY_RATE_LIMIT_MAX_REQUESTS = 30;

export type ChatGatewayRateLimitActor = {
  actorType: "agent" | "board";
  actorId: string;
};

export type ChatGatewayRateLimitResult = {
  allowed: boolean;
  limit: number;
  remaining: number;
  retryAfterSeconds: number;
};

export type ChatGatewayRateLimiter = {
  consume(actor: ChatGatewayRateLimitActor): ChatGatewayRateLimitResult;
};

export function createChatGatewayRateLimiter(options: {
  windowMs?: number;
  maxRequests?: number;
  now?: () => number;
} = {}): ChatGatewayRateLimiter {
  const windowMs =
    options.windowMs ?? CHAT_GATEWAY_RATE_LIMIT_WINDOW_MS;
  const maxRequests =
    options.maxRequests ?? CHAT_GATEWAY_RATE_LIMIT_MAX_REQUESTS;
  const now = options.now ?? Date.now;
  const hitsByKey = new Map<string, number[]>();

  function key(actor: ChatGatewayRateLimitActor) {
    return `${actor.actorType}:${actor.actorId}`;
  }

  return {
    consume(actor) {
      const currentTime = now();
      const cutoff = currentTime - windowMs;
      const actorKey = key(actor);
      const recentHits = (hitsByKey.get(actorKey) ?? []).filter(
        (hit) => hit > cutoff,
      );

      if (recentHits.length >= maxRequests) {
        const oldestHit = recentHits[0] ?? currentTime;
        hitsByKey.set(actorKey, recentHits);
        return {
          allowed: false,
          limit: maxRequests,
          remaining: 0,
          retryAfterSeconds: Math.max(
            1,
            Math.ceil((oldestHit + windowMs - currentTime) / 1000),
          ),
        };
      }

      recentHits.push(currentTime);
      hitsByKey.set(actorKey, recentHits);
      return {
        allowed: true,
        limit: maxRequests,
        remaining: Math.max(0, maxRequests - recentHits.length),
        retryAfterSeconds: 0,
      };
    },
  };
}