# Helios V4 — React Orchestration Layer Specification

A specification for a React orchestration layer over the Helios V4 election API.
The design is a strict four-layer architecture: **API Client → Repository
(TanStack Query) → Service → Presentation**. Each layer is a one-way dependency
on the layer below it. Layers above the Repository never import `@tanstack/react-query`
directly; layers below the Service never know about a screen.

---

## 1. Goals & Non-Goals

### Goals
- A single, testable boundary between HTTP and the rest of the app.
- TanStack Query as an implementation detail of the Repository layer, not a
  cross-cutting concern leaked into components.
- Domain-shaped APIs (`useCreateElection`, `useCastBallot`) instead of
  endpoint-shaped APIs (`usePostElectionsUuidCast`).
- A predictable place for the workflow logic implied by Helios's multi-step
  rituals (freeze, cast → cast_confirm, tally → combine_decryptions →
  release_result).
- Cache coherency: a freeze, a cast, or a result release invalidates the
  right neighbors and nothing more.

### Non-Goals
- Defining the wire format of Helios endpoints (the API doc is the source of truth).
- Specifying the encryption library used for client-side ballot encryption.
- Picking a routing library, form library, or component kit.

---

## 2. Layer Overview

```
┌──────────────────────────────────────────────────────────┐
│  Presentation                                            │
│  React components. Read state from Service hooks,        │
│  dispatch intents via Service hooks. No QueryClient,     │
│  no fetch, no query keys.                                │
└──────────────────────────┬───────────────────────────────┘
                           │  consumes
┌──────────────────────────▼───────────────────────────────┐
│  Service                                                 │
│  Domain hooks. Orchestrates multi-call workflows         │
│  (e.g. cast-then-confirm), enforces invariants, maps     │
│  repository errors to domain errors. Pure of HTTP and    │
│  pure of UI.                                             │
└──────────────────────────┬───────────────────────────────┘
                           │  uses
┌──────────────────────────▼───────────────────────────────┐
│  Repository (TanStack Query)                             │
│  One module per resource (elections, voters, trustees,   │
│  ballots, results, auth). Owns query keys, cache         │
│  policies, optimistic updates, and invalidation graph.   │
│  Returns native TanStack types (UseQueryResult,          │
│  UseMutationResult).                                     │
└──────────────────────────┬───────────────────────────────┘
                           │  uses
┌──────────────────────────▼───────────────────────────────┐
│  API Client                                              │
│  A typed HTTP module. Auth interceptor, JSON encoding,   │
│  error normalization, retry policy. One function per     │
│  endpoint. No React. No cache.                           │
└──────────────────────────────────────────────────────────┘
```

**Rule of thumb:** if a file imports `@tanstack/react-query`, it lives in
`repositories/` or is the `QueryClient` bootstrap. Nothing else.

---

## 3. Directory Layout

```
src/
  api/
    client.ts                 // axios/fetch instance, interceptors
    errors.ts                 // HeliosApiError + normalization
    endpoints/
      auth.ts                 // register, login
      elections.ts            // create, copy, get, freeze, …
      questions.ts            // set questions
      voters.ts               // upload, generate_pin, password_voter_login
      trustees.ts             // add, upload-pk, upload-decryption
      ballots.ts              // encrypt-ballot, cast, cast_confirm, vh
      results.ts              // compute_tally, combine_decryptions, release_result, pretty_result
      tools.ts                // generate_pins
    types.ts                  // wire-shape DTOs

  repositories/
    queryKeys.ts              // single source of truth for keys
    queryClient.ts            // QueryClient factory + defaults
    auth.repo.ts
    elections.repo.ts
    questions.repo.ts
    voters.repo.ts
    trustees.repo.ts
    ballots.repo.ts
    results.repo.ts
    tools.repo.ts

  services/
    auth.service.ts           // useSession, useLogin, useRegister
    electionAdmin.service.ts  // useElectionLifecycle, useFreezeElection
    trustee.service.ts        // useTrusteeOnboarding, useTrusteeDecryption
    voter.service.ts          // useVoterSession, useCastBallotWorkflow
    results.service.ts        // useElectionResults
    errors.ts                 // DomainError taxonomy

  presentation/
    pages/
    components/
    forms/

  app/
    providers.tsx             // QueryClientProvider, AuthProvider
    router.tsx
```

---

## 4. API Client Layer

### 4.1 Responsibilities
- One typed function per endpoint listed in the Helios doc.
- Inject `Authorization: Bearer <jwt>` from the auth store when present.
- Distinguish admin JWT (from `/auth/login`) vs. voter JWT
  (from `/elections/{uuid}/password_voter_login`) vs. trustee JWT. The client
  accepts an explicit `authScope` so callers cannot accidentally send a voter
  JWT to an admin endpoint.
- Normalize errors into `HeliosApiError { status, code, message, details }`.
- Network-level retries (idempotent GETs only); 401 → emit auth-expired event.

### 4.2 Endpoint Inventory

| Group     | Function                          | HTTP                                                              |
| --------- | --------------------------------- | ----------------------------------------------------------------- |
| auth      | `register`                        | `POST /auth/register`                                             |
| auth      | `login`                           | `POST /auth/login`                                                |
| tools     | `generatePins`                    | `POST /tools/generate_pins`                                       |
| elections | `createElection`                  | `POST /elections`                                                 |
| elections | `copyElection`                    | `POST /elections/{uuid}/copy`                                     |
| elections | `setQuestions`                    | `POST /elections/{uuid}/questions`                                |
| elections | `freezeElection`                  | `POST /elections/{uuid}/freeze`                                   |
| voters    | `generateVoterPins`               | `POST /elections/{uuid}/voters/generate_pin`                      |
| voters    | `uploadVoters`                    | `POST /elections/{uuid}/voters/upload`                            |
| voters    | `voterLogin`                      | `POST /elections/{uuid}/password_voter_login`                     |
| trustees  | `addTrustee`                      | `POST /elections/{uuid}/trustees`                                 |
| trustees  | `uploadTrusteePublicKey`          | `POST /elections/{uuid}/trustees/{tuuid}/upload-pk`               |
| trustees  | `uploadTrusteeDecryption`         | `POST /elections/{uuid}/trustees/{tuuid}/upload-decryption`       |
| ballots   | `encryptBallot`                   | `POST /elections/{uuid}/encrypt-ballot`                           |
| ballots   | `castBallot`                      | `POST /elections/{uuid}/cast`                                     |
| ballots   | `confirmCastBallot`               | `POST /elections/{uuid}/cast_confirm`                             |
| ballots   | `getBallotByHash`                 | `GET /elections/vh/{vote_hash}`                                   |
| results   | `computeTally`                    | `POST /elections/{uuid}/compute_tally`                            |
| results   | `combineDecryptions`              | `POST /elections/{uuid}/combine_decryptions`                      |
| results   | `releaseResult`                   | `POST /elections/{uuid}/release_result`                           |
| results   | `getPrettyResult`                 | `GET /elections/{uuid}/pretty_result`                             |

### 4.3 Error Normalization

```ts
class HeliosApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,       // e.g. "ELECTION_FROZEN", "INVALID_PIN"
    message: string,
    readonly details?: unknown,
  ) { super(message); }
}
```

Repositories pass `HeliosApiError` through unchanged. Services translate it
into a `DomainError` (§7.4) the presentation layer can switch on.

---

## 5. Repository Layer (TanStack Query)

### 5.1 Query Keys

Centralized, hierarchical, and the **only** place keys are constructed.
Hierarchy mirrors invalidation scope.

```ts
// repositories/queryKeys.ts
export const qk = {
  auth: {
    session: ['auth', 'session'] as const,
  },
  elections: {
    all:     ['elections'] as const,
    detail:  (uuid: string) => ['elections', uuid] as const,
    questions:(uuid: string) => ['elections', uuid, 'questions'] as const,
    voters:  (uuid: string) => ['elections', uuid, 'voters'] as const,
    trustees:(uuid: string) => ['elections', uuid, 'trustees'] as const,
    result:  (uuid: string) => ['elections', uuid, 'result'] as const,
  },
  ballots: {
    byHash:  (h: string) => ['ballots', 'vh', h] as const,
  },
} as const;
```

### 5.2 Repository Module Shape

Every repository exports hooks. No repository exports a component.

```ts
// repositories/elections.repo.ts
export function useElection(uuid: string) {
  return useQuery({
    queryKey: qk.elections.detail(uuid),
    queryFn: () => api.elections.get(uuid),
    enabled: !!uuid,
  });
}

export function useCreateElection() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: api.elections.create,
    onSuccess: (created) => {
      qc.setQueryData(qk.elections.detail(created.uuid), created);
      qc.invalidateQueries({ queryKey: qk.elections.all });
    },
  });
}

export function useFreezeElection(uuid: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => api.elections.freeze(uuid),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: qk.elections.detail(uuid) });
      qc.invalidateQueries({ queryKey: qk.elections.trustees(uuid) });
    },
  });
}
```

### 5.3 Mutation → Invalidation Map

Cache coherency is described once, here, so reviewers can audit it.

| Mutation                          | Invalidates                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `useCreateElection`               | `elections.all`; seeds `elections.detail(new.uuid)`                                  |
| `useCopyElection`                 | `elections.all`; seeds `elections.detail(new.uuid)`                                  |
| `useSetQuestions(uuid)`           | `elections.questions(uuid)`, `elections.detail(uuid)`                                |
| `useUploadVoters(uuid)`           | `elections.voters(uuid)`                                                             |
| `useGenerateVoterPins(uuid)`      | `elections.voters(uuid)`                                                             |
| `useAddTrustee(uuid)`             | `elections.trustees(uuid)`, `elections.detail(uuid)`                                 |
| `useUploadTrusteePublicKey(...)`  | `elections.trustees(uuid)`, `elections.detail(uuid)`                                 |
| `useFreezeElection(uuid)`         | `elections.detail(uuid)`, `elections.trustees(uuid)`                                 |
| `useVoterLogin(uuid)`             | `auth.session`                                                                       |
| `useEncryptBallot(uuid)`          | none (pure computation surrogate)                                                    |
| `useCastBallot(uuid)`             | none (server holds in memory until confirm)                                          |
| `useConfirmCastBallot(uuid)`      | `ballots.byHash(hash)` (seeded); `elections.detail(uuid)` if it exposes turnout      |
| `useUploadTrusteeDecryption(...)` | `elections.trustees(uuid)`, `elections.result(uuid)`                                 |
| `useComputeTally(uuid)`           | `elections.detail(uuid)`, `elections.result(uuid)`                                   |
| `useCombineDecryptions(uuid)`     | `elections.result(uuid)`                                                             |
| `useReleaseResult(uuid)`          | `elections.detail(uuid)`, `elections.result(uuid)`                                   |

### 5.4 Cache Defaults
- `staleTime`: 30s for entities (`election`, `voters`, `trustees`); `Infinity`
  for immutable artifacts (`pretty_result` once released, `ballots.byHash`).
- `retry`: 2 for queries, 0 for mutations.
- `refetchOnWindowFocus`: false (election admin screens are long-lived forms).

### 5.5 What Repositories Must NOT Do
- No business rules (e.g. "you must have ≥ 1 question before freezing"). That
  belongs in Service.
- No toast/snackbar side effects.
- No router navigation.
- No chaining of mutations. A repo hook calls exactly one endpoint.

---

## 6. Service Layer

The service layer is where Helios's multi-step rituals are encoded. Services
are React hooks; they return a domain-shaped object instead of leaking
`UseMutationResult`.

### 6.1 Service Hook Shape

```ts
type AsyncCommand<TArgs, TResult> = {
  run: (args: TArgs) => Promise<TResult>;
  status: 'idle' | 'pending' | 'success' | 'error';
  error: DomainError | null;
  reset: () => void;
};
```

Queries follow a similar pattern:

```ts
type AsyncQuery<T> = {
  data: T | undefined;
  status: 'idle' | 'loading' | 'success' | 'error';
  error: DomainError | null;
  refetch: () => Promise<void>;
};
```

### 6.2 Catalogue of Services

#### `auth.service.ts`
- `useSession()` — returns `{ user, role, token }` or `null`.
- `useLogin()` — wraps `useLoginMutation`; on success persists JWT and seeds
  `auth.session`.
- `useRegister()` — wraps register, optionally auto-logs-in.
- `useLogout()` — clears token, calls `queryClient.clear()`.

#### `electionAdmin.service.ts`
Encapsulates the **Before an Election** ritual.

- `useCreateElection()` — input domain shape, output `{ uuid, shortName }`.
- `useCopyElection(sourceUuid)`.
- `useElectionLifecycle(uuid)` — composite query returning:
  ```ts
  {
    election, questions, voters, trustees,
    readinessChecklist: {
      hasQuestions: boolean,
      hasVoters: boolean,
      allTrusteesUploadedPk: boolean,
      canFreeze: boolean,
    }
  }
  ```
- `useSetQuestions(uuid)`.
- `useAddVoters(uuid)` — chooses between `generate_pin` (sync, header row) and
  `upload` (Celery, no header row) based on input shape. Presentation
  doesn't pick the endpoint; service does.
- `useAddTrustee(uuid)`.
- `useFreezeElection(uuid)` — guards with `readinessChecklist.canFreeze`;
  surfaces `DomainError.NotReadyToFreeze` instead of letting the 4xx leak.

#### `trustee.service.ts`
- `useTrusteeOnboarding(uuid, tuuid)` — `submitPublicKey(pk, pok)`.
- `useTrusteeDecryption(uuid, tuuid)` — `submitDecryption(...)`.

#### `voter.service.ts`
Encapsulates the **During an Election** ritual. The two-phase cast/confirm
flow is the canonical reason this layer exists.

- `useVoterSession(uuid)` — `login(username, pin)`; returns voter JWT.
- `useCastBallotWorkflow(uuid)` — exposes one method:
  ```ts
  cast(selections: number[][], opts?: { clientEncryption?: boolean }):
    Promise<{ voteHash: string }>
  ```
  Internally:
  1. If `clientEncryption`, run local encrypt; else call `encrypt-ballot`.
  2. `POST /cast` to stash in memory.
  3. `POST /cast_confirm` to persist.
  4. If step 3 fails, surface `DomainError.BallotRejected` and **do not** report
     success — this addresses the known gap in the API doc where the user is
     not alerted to invalidation.
  5. On success, return `voteHash` and seed `qk.ballots.byHash(voteHash)`.
- `useBallotStatus(voteHash)`.

#### `results.service.ts`
Encapsulates the **After an Election** ritual.

- `useElectionResults(uuid)` — composite query:
  ```ts
  {
    phase: 'tallying' | 'awaiting-decryptions' | 'combining' | 'released' | 'pre-tally',
    pretty: PrettyResult | null,
    trusteesPending: TrusteeRef[],
  }
  ```
- `useTallyWorkflow(uuid)`:
  - `computeTally()`
  - `combineDecryptions()` (guarded: requires all trustee decryptions)
  - `releaseResult()` (guarded: requires combine to have succeeded)

### 6.3 Composition Example

```ts
// services/voter.service.ts
export function useCastBallotWorkflow(uuid: string) {
  const encrypt = useEncryptBallot(uuid);          // repo
  const cast    = useCastBallot(uuid);             // repo
  const confirm = useConfirmCastBallot(uuid);      // repo
  const qc      = useQueryClient();                // allowed: service may seed cache

  const run = useCallback(async (selections, opts) => {
    const ciphertext = opts?.clientEncryption
      ? await clientEncrypt(selections, /* election pk */)
      : await encrypt.mutateAsync({ answers: selections });

    const { castId } = await cast.mutateAsync({ ciphertext });

    try {
      const { voteHash } = await confirm.mutateAsync({ castId });
      qc.setQueryData(qk.ballots.byHash(voteHash), { status: 'accepted', uuid });
      return { voteHash };
    } catch (e) {
      throw toDomainError(e, { default: DomainError.BallotRejected });
    }
  }, [encrypt, cast, confirm, qc]);

  return { run, status: deriveStatus(encrypt, cast, confirm), error: deriveError(...) };
}
```

### 6.4 Allowed Imports by Layer

| Layer         | May import                                              | May NOT import                       |
| ------------- | ------------------------------------------------------- | ------------------------------------ |
| API Client    | `axios`, `zod`                                          | React, TanStack, components          |
| Repository    | API Client, `@tanstack/react-query`, query keys         | Components, services, router         |
| Service       | Repositories, `useQueryClient` (cache seeding only)     | API Client directly, components      |
| Presentation  | Services                                                | Repositories, API Client, TanStack   |

A lint rule (`eslint-plugin-boundaries` or `import/no-restricted-paths`)
enforces this.

---

## 7. Cross-Cutting Concerns

### 7.1 Auth & Token Storage
- A small `AuthStore` (zustand or React Context) holds `{ adminJwt,
  voterJwt, trusteeJwt }`. The API client reads from it.
- Voter and trustee JWTs are scoped per election uuid and cleared on logout
  or on `useReleaseResult` completion (voter session ends with the election).
- A 401 response triggers `AuthStore.invalidate(scope)` and `queryClient
  .invalidateQueries({ queryKey: qk.auth.session })`.

### 7.2 Optimistic Updates
- `useFreezeElection` flips `election.frozen` optimistically and rolls back on
  error.
- `useAddTrustee` appends optimistically.
- Ballot mutations are **not** optimistic — the two-phase protocol exists
  precisely because the server is the source of truth.

### 7.3 Long-Running Celery Tasks
- `voters/upload` may return a task handle. The voters repository exposes
  `useVoterUploadStatus(taskId)` that polls until terminal. The service hook
  `useAddVoters` hides this — callers `await`-able until success/failure.

### 7.4 Domain Error Taxonomy

```ts
type DomainError =
  | { kind: 'NotAuthenticated' }
  | { kind: 'WrongAuthScope' }
  | { kind: 'NotReadyToFreeze'; missing: ('questions'|'voters'|'trusteeKeys')[] }
  | { kind: 'ElectionFrozen' }
  | { kind: 'InvalidVoterCredentials' }
  | { kind: 'BallotRejected'; reason?: string }
  | { kind: 'TrusteeDecryptionMissing'; trusteeIds: string[] }
  | { kind: 'ResultNotReleased' }
  | { kind: 'Network' }
  | { kind: 'Unknown'; cause: HeliosApiError };
```

Mapping from `HeliosApiError.code` to `DomainError.kind` lives in
`services/errors.ts`. Components switch on `DomainError.kind`.

### 7.5 Testing Strategy
- **API Client**: unit tests with MSW; assert wire shapes against the spec.
- **Repositories**: render in isolation with a fresh `QueryClient`; assert
  query keys, cache writes, and invalidation. No service or component involved.
- **Services**: render with mocked repositories (jest module mock) to verify
  orchestration order, guard conditions, and error mapping.
- **Presentation**: render with mocked services; assert UI behavior, not
  network behavior.

### 7.6 Type Safety
- Wire DTOs live in `api/types.ts` and are validated with `zod` at the API
  client boundary. Everything above the API Client speaks in domain types
  (`Election`, `Voter`, `Trustee`, `Ballot`, `PrettyResult`).
- The mapping `dto → domain` happens in `api/endpoints/*` so repositories and
  services never see snake_case.

---

## 8. End-to-End Walkthrough: Casting a Ballot

To illustrate how the layers compose, here is the cast flow described in the
Helios doc.

1. **Presentation** — `<BallotForm>` collects `selections: number[][]`.
2. **Service** — `useCastBallotWorkflow(uuid).run(selections)`:
   1. Calls `useEncryptBallot` (repo) or local encrypt.
   2. Calls `useCastBallot` (repo) → server memory cache.
   3. Calls `useConfirmCastBallot` (repo) → persisted.
3. **Repository** — each step issues one mutation, normalizes the response,
   and seeds `qk.ballots.byHash(voteHash)` on confirm.
4. **API Client** — issues `POST /elections/{uuid}/encrypt-ballot`,
   `POST /elections/{uuid}/cast`, `POST /elections/{uuid}/cast_confirm`
   with the voter JWT.
5. On error at any step, Service throws `DomainError.BallotRejected`;
   `<BallotForm>` renders the rejection state. The user is *never* told their
   ballot was cast if `cast_confirm` did not return success — closing the gap
   the Helios doc flags.

---

## 9. Acceptance Criteria

- [ ] All endpoints from §4.2 are implemented in `api/endpoints/*`.
- [ ] Every endpoint has exactly one repository hook; repository hooks call
      exactly one endpoint.
- [ ] The invalidation map in §5.3 is implemented and covered by tests.
- [ ] No file outside `repositories/` or `app/providers.tsx` imports
      `@tanstack/react-query`.
- [ ] No file outside `api/` imports `axios`/`fetch`.
- [ ] Services expose domain-shaped APIs (§6.1); no `UseMutationResult` leaks
      into presentation.
- [ ] `useCastBallotWorkflow` surfaces `BallotRejected` on `cast_confirm`
      failure and does not mark the ballot as cast.
- [ ] Freeze, tally, combine_decryptions, and release_result are each guarded
      in their service by an explicit readiness check.
- [ ] Lint rule enforcing the import boundaries from §6.4 is in CI.
