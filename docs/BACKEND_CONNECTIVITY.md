# USB-free backend connectivity — proposal only

## Current working path

The physical phone uses http://127.0.0.1:8080 with ADB reverse. A development computer's authorized gcloud proxy forwards to the private testing Cloud Run service. Firebase Authentication is still checked by FastAPI. Android Emulator can reach a host proxy at http://10.0.2.2:8080. Both development approaches require a running computer/proxy; App Distribution only delivers an APK.

A Firebase ID token and the Google IAM ID token expected by private Cloud Run have different audiences/issuers. Putting the private Cloud Run URL in the APK is insufficient. Never embed a Google service-account key, privileged identity, fixed cloud token or provider secret in Android. No IAM or public access was changed during this preparation.

## Separate proposal requiring security and cost approval

A small Firebase-authenticated HTTPS streaming relay is a possible next step. It would validate the mobile Firebase token and forward the existing Authorization bearer token unchanged to the current FastAPI backend, while adding a Google-managed service identity token in X-Serverless-Authorization for IAM-private Cloud Run. Google documents that when both headers are present, IAM checks X-Serverless-Authorization. [Cloud Run service-to-service authentication](https://docs.cloud.google.com/run/docs/authenticating/service-to-service).

The relay's dedicated service identity would need invocation access to the testing service only, not Firestore, provider secrets or the stable service. A separate externally reachable relay endpoint would require explicit approval and application-level Firebase authentication; the existing backend remains private. This is a design proposal, not implemented/deployed infrastructure. Adding the relay, its narrow invoker binding, domain/API URL and any recurring costs require separate approval. Do not bundle these with GitHub or APK upload approval.

A managed API Gateway is another option to evaluate. Its Firebase auth configuration replaces/forwards auth headers differently, so the current backend's Firebase token verification path must be checked rather than assumed compatible. Streaming and timeout behavior must also be verified. [Firebase authentication in API Gateway](https://docs.cloud.google.com/api-gateway/docs/authenticating-users-firebase).

## Verification required before enabling distribution

Verify Firebase login and saved-allergy reads over the approved HTTPS endpoint without USB or laptop proxy. Reject missing/expired/wrong-project tokens and cross-user access. Preserve backend token verification and role boundaries. Verify actual incremental Dish/Label SSE delivery, heartbeat forwarding, request timeout alignment, cancellation/disconnect behavior, no buffering, no duplicate paid requests, and safe logs. Use synthetic fixtures/mock providers for automated checks and obtain separate approval before real paid scans.

Record the reviewed endpoint and evidence, then separately approve mobile_connectivity_verified and mobile_api_base_url in policy.json. Until then the APK workflow is intentionally blocked. No new endpoint or unaudited proxy was added in this task.
