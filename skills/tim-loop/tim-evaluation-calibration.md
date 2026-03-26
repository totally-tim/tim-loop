# Evaluation Calibration Reference

This file is the single source of truth for scoring criteria, thresholds, and calibration examples. Both the verifier and auditor read this on their first turn to align their evaluation standards.

## Scoring Dimensions

### Verifier Dimensions (command-based, scored 1-10)

| Dimension | What It Measures | How to Derive Score |
|---|---|---|
| **Functional completeness** | Do all P0 requirements work end-to-end? | Score = (P0 requirements with status IMPLEMENTED / total P0 requirements) * 10. Round down. If any P0 is MISSING, cap at 5. |
| **Code health** | Typecheck clean, lint clean, test pass rate, no new warnings? | Start at 10. Subtract 1 per typecheck error, 0.5 per lint warning, 1 per failing test. Floor at 1. |
| **Integration coherence** | All connections wired, no stubs, no dead exports? | Start at 10. Subtract 2 per stub found, 2 per dead export, 1 per missing connection. Add 1 if interactive smoke check passed (pages render, navigation works, no console errors). Floor at 1. |

### Auditor Dimensions (source-reading, scored 1-10)

| Dimension | What It Measures | How to Derive Score |
|---|---|---|
| **Implementation depth** | Ratio of REAL to STUB/MISSING across all requirements | Score = (REAL count / total requirements) * 10. Round down. If any P0 is STUB or MISSING, cap at 5. |
| **Test thoroughness** | Ratio of THOROUGH to SHALLOW/MISSING across all requirements | Score = (THOROUGH count / total requirements) * 10. Subtract 1 per SHALLOW (tests exist but are weak). Floor at 1. |
| **Spec fidelity** | How closely does implementation match spec *intent*, not just letter | Subjective judgment. 10 = implementation captures the spirit of every requirement, handles edge cases the spec implied but didn't enumerate. 5 = technically meets requirements but misses obvious intent. 1 = implementation diverges from spec purpose. |

## Hard Threshold

**No dimension below 6.** If any single dimension scores below 6, the build FAILS — regardless of whether all tests pass.

Score 6 exactly = PASS (threshold is "below 6", not "at or below 6").

## Anti-Leniency Directives

These rules override your natural inclination to be generous:

1. **If you identify an issue, it IS significant.** Do not rationalize it away. Do not say "but it mostly works." Do not downgrade a finding because fixing it would be hard.

2. **Your job is to find problems, not to be encouraging.** A generous evaluation wastes builder iterations on a doomed approach. The builder needs honest signal, not praise.

3. **When in doubt, FAIL.** False negatives (missed issues that escape to the PR) are 10x more expensive than false positives (extra fix iterations). Err on the side of catching too much.

4. **Never upgrade a STUB to REAL because "it mostly works."** If the core business logic is missing — if the function is a pass-through, returns hardcoded data, or delegates to an unimplemented helper — it is a STUB. Period.

5. **Never upgrade SHALLOW to THOROUGH because "the test file exists."** Read the assertions. If they only check existence (`toBeDefined`), only test the happy path, or mock everything, the test is SHALLOW regardless of how many lines it has.

6. **Do not talk yourself into approving.** When you notice yourself writing justifications for why something is "good enough," stop. That's the leniency bias. Re-read the criteria and score again from scratch.

7. **A passing test suite does not mean the implementation is good.** Tests can pass while the implementation uses hardcoded values, stubs out error paths, or only handles the exact inputs the tests use. Score based on what you observe in the source, not what the test runner reports.

## Few-Shot Calibration Examples

### Example 1: Too-Lenient Assessment (WRONG) → Corrected Assessment

**Scenario:** A rate-limiting middleware for auth endpoints.

**Code:**
```typescript
export function rateLimit(config: RateLimitConfig) {
  const store = new Map<string, number[]>();
  return (req: Request, res: Response, next: NextFunction) => {
    const key = req.ip;
    const now = Date.now();
    const timestamps = store.get(key) || [];
    const recent = timestamps.filter(t => now - t < config.windowMs);
    if (recent.length >= config.max) {
      return res.status(429).json({ error: 'Too many requests' });
    }
    recent.push(now);
    store.set(key, recent);
    next();
  };
}
```

**Test:**
```typescript
it('should rate limit requests', () => {
  const limiter = rateLimit({ windowMs: 1000, max: 2 });
  const req = { ip: '127.0.0.1' };
  const res = { status: jest.fn().mockReturnThis(), json: jest.fn() };
  const next = jest.fn();

  limiter(req, res, next); // 1st request
  expect(next).toHaveBeenCalled();
});
```

**WRONG assessment (too lenient):**
> Implementation looks solid — has a sliding window store, checks against max, returns 429. Test verifies the happy path works. implementation_depth: 8, test_thoroughness: 7.

**CORRECTED assessment:**
> Implementation is REAL (contains actual rate-limiting logic with windowing). However, it uses an in-memory Map that won't work across server restarts or multiple instances — a significant gap for production use. Test is SHALLOW — it only tests one request (happy path). It never verifies that the 429 is returned after exceeding the limit. It never tests the window expiry. It never tests concurrent requests.

> **implementation_depth: 7** (REAL but missing production concerns — no persistence, no clustering)
> **test_thoroughness: 3** (exists but only tests happy path, never exercises the rate-limiting behavior it claims to test)

### Example 2: Borderline Pass (6/10)

**Scenario:** Error toast component for failed login.

**Code:**
```tsx
export function ErrorToast({ message, onClose }: ErrorToastProps) {
  useEffect(() => {
    const timer = setTimeout(onClose, 5000);
    return () => clearTimeout(timer);
  }, [onClose]);

  return (
    <div role="alert" className="error-toast">
      <span>{message}</span>
      <button onClick={onClose}>Dismiss</button>
    </div>
  );
}
```

**Test:**
```typescript
it('renders error message', () => {
  render(<ErrorToast message="Login failed" onClose={jest.fn()} />);
  expect(screen.getByText('Login failed')).toBeInTheDocument();
  expect(screen.getByRole('alert')).toBeInTheDocument();
});

it('calls onClose after timeout', () => {
  jest.useFakeTimers();
  const onClose = jest.fn();
  render(<ErrorToast message="Error" onClose={onClose} />);
  jest.advanceTimersByTime(5000);
  expect(onClose).toHaveBeenCalled();
});
```

**Assessment:**
> Implementation is REAL — renders message, auto-dismisses, has accessible role. Missing: no animation, no severity levels, no stacking for multiple errors. These are P1/P2 concerns, not P0 blockers.

> Test covers happy path (render + display) AND the timeout behavior. Missing: dismiss button click test, edge case of rapid mount/unmount, no test for accessibility.

> **implementation_depth: 7** (REAL, handles core behavior, missing polish)
> **test_thoroughness: 6** (covers main behaviors, missing edge cases — borderline acceptable)

### Example 3: Clear Fail (3/10)

**Scenario:** Invoice generation endpoint.

**Code:**
```typescript
export async function generateInvoice(req: Request, res: Response) {
  // TODO: implement invoice generation
  const invoice = {
    id: 'inv-001',
    amount: 100,
    status: 'draft'
  };
  res.json(invoice);
}
```

**Test:**
```typescript
it('should generate invoice', async () => {
  const res = await request(app).post('/api/invoices');
  expect(res.status).toBe(200);
  expect(res.body).toBeDefined();
});
```

**Assessment:**
> Implementation is STUB — returns hardcoded data with a TODO comment. No actual invoice generation logic. No database interaction. No input validation. The endpoint technically responds with 200, but it does nothing useful.

> Test is SHALLOW — only checks that the endpoint doesn't crash (status 200) and that `body` exists. Doesn't verify any invoice properties, doesn't test with different inputs, doesn't test error cases.

> **implementation_depth: 2** (STUB with TODO, hardcoded response)
> **test_thoroughness: 2** (existence check only, no meaningful assertions)

### Example 4: High-Quality Pass (9/10)

**Scenario:** JWT refresh token rotation.

**Code:**
```typescript
export async function rotateRefreshToken(token: string): Promise<TokenPair> {
  const decoded = verifyRefreshToken(token);
  if (!decoded) throw new AuthError('Invalid refresh token', 401);

  const isRevoked = await tokenStore.isRevoked(token);
  if (isRevoked) {
    await tokenStore.revokeAllForUser(decoded.userId);
    throw new AuthError('Token reuse detected - all sessions revoked', 401);
  }

  await tokenStore.revoke(token);
  const newAccess = signAccessToken({ userId: decoded.userId, role: decoded.role });
  const newRefresh = signRefreshToken({ userId: decoded.userId });
  await tokenStore.store(newRefresh, decoded.userId);

  return { accessToken: newAccess, refreshToken: newRefresh };
}
```

**Test:**
```typescript
describe('rotateRefreshToken', () => {
  it('issues new token pair for valid refresh token', async () => {
    const { accessToken, refreshToken } = await rotateRefreshToken(validToken);
    expect(accessToken).toBeTruthy();
    expect(refreshToken).toBeTruthy();
    expect(refreshToken).not.toBe(validToken);
  });

  it('revokes the old refresh token after rotation', async () => {
    await rotateRefreshToken(validToken);
    expect(await tokenStore.isRevoked(validToken)).toBe(true);
  });

  it('rejects expired refresh tokens', async () => {
    await expect(rotateRefreshToken(expiredToken)).rejects.toThrow('Invalid refresh token');
  });

  it('detects token reuse and revokes all sessions', async () => {
    await rotateRefreshToken(validToken); // first use
    await expect(rotateRefreshToken(validToken)).rejects.toThrow('Token reuse detected');
    const userTokens = await tokenStore.getActiveTokens(userId);
    expect(userTokens).toHaveLength(0);
  });

  it('preserves user role in new access token', async () => {
    const { accessToken } = await rotateRefreshToken(validToken);
    const decoded = verifyAccessToken(accessToken);
    expect(decoded.role).toBe('admin');
  });
});
```

**Assessment:**
> Implementation is REAL — full rotation logic with token reuse detection (a security best practice many implementations miss), automatic session revocation on reuse, proper error handling with specific error types. Well-structured with clear flow.

> Tests are THOROUGH — cover happy path (rotation works), security critical path (reuse detection + session revocation), error handling (expired tokens), and data integrity (role preservation). Each test asserts specific meaningful behavior, not just existence.

> **implementation_depth: 9** (REAL with security best practices, only missing logging/metrics)
> **test_thoroughness: 9** (THOROUGH, covers happy + error + security + edge cases)

### Example 5: Score-vs-Test Conflict (Tests Pass, Score Fails)

**Scenario:** Search endpoint with pagination.

**Code:**
```typescript
export async function searchProducts(query: string, page: number, limit: number) {
  // Hardcoded for now - TODO: connect to real search
  return {
    results: [
      { id: 1, name: 'Widget', price: 9.99 },
      { id: 2, name: 'Gadget', price: 19.99 }
    ],
    total: 2,
    page: 1,
    limit: 10
  };
}
```

**Test:**
```typescript
it('returns search results', async () => {
  const result = await searchProducts('widget', 1, 10);
  expect(result.results).toHaveLength(2);
  expect(result.results[0].name).toBe('Widget');
  expect(result.total).toBe(2);
  expect(result.page).toBe(1);
});
```

**Assessment:**
> ALL TESTS PASS. The test asserts `results` has length 2 and the first item is "Widget" — and the hardcoded implementation returns exactly that. The test framework reports green.

> But this is a STUB. The function ignores `query`, `page`, and `limit` parameters entirely. It always returns the same hardcoded array. The test passes only because its expectations match the hardcoded data. A real search with "gadget" would still return "Widget" first. Pagination is completely non-functional.

> **implementation_depth: 2** (STUB — hardcoded response, ignores all parameters)
> **test_thoroughness: 3** (assertions match hardcoded data, never tests actual search behavior, pagination, or different queries)
> **Verdict: FAIL** despite green tests. Score 2 < threshold 6.

## When Scores Disagree with Binary Results

If all tests pass (Phase 1+2 PASS) but any dimension scores below 6:
- The build **FAILS** — score gates everything
- Include in feedback: "Tests pass but implementation quality below bar. Dimension X scored Y/10: [rationale]"
- The builder needs to improve the specific dimension, not just make tests pass

If tests fail but scores would be high:
- The build **FAILS** — tests are still a hard gate
- Tests and scores are independent gates: both must pass

## How to Use This File

1. Read this file on your **first turn** before doing any evaluation work
2. Score each dimension independently — don't let a high score on one dimension compensate for a low score on another
3. Include `quality_scores` and `score_rationale` in your task metadata
4. Reference the relevant calibration example when your assessment is close to a boundary (5-7 range)
5. If you catch yourself writing justifications for why something is "good enough," re-read the Anti-Leniency Directives above
