# Firebase App Distribution and signing plan — inactive

## Verified identity

Firebase project: misbar-ebea2; registered Android app: 1:237433634785:android:2b820ecdacd9d581a65ca0. Package: com.example.flutter_application_1.misbar2. The Android app registration was read from the Firebase Management API and matched the existing flavor configuration. The connected Lenovo's installed APK matched the last approved APK exactly. The existing local debug keystore's public certificate also matched that APK:

```text
8874e811d876ef3b978f0c73c653f0c7d55b26db88febcf79560ecfce2add964
```

The key already exists; no key was generated or changed. Its private bytes were not copied into the repository or a cloud secret. The approved second-copy flavor is debug-only, so this internal pilot preserves that build mode. Do not remove its release restriction or invent a new key. A later production release would be a distinct signing/build decision.

## Prepared pipeline

android-distribution.yml.disabled reacts to reviewed main frontend changes only after its explicit activation. The unprivileged build job runs Flutter tests/analysis and builds an APK without the approved private key. A short-retention artifact passes that APK to a separately protected upload job. The upload job uses WIF/ADC, retrieves the existing approved signing identity from a separately approved Secret Manager secret version, signs with first-party Android apksigner, and checks package/certificate/version before upload. No key enters the APK, Git, build artifact or Gradle project. The signing key exists only in runner temporary storage and is cleaned on success/failure.

The version code is the reviewed base 1000 plus workflow run number, with bounds checking; the installed approved application used code 1. If a workflow is renamed or existing release version codes are higher, review/increase the base before activation. Do not choose a lower code to force a downgrade.

firebase_distribution.py uses the official upload/operation API through short-lived ADC credentials. It logs only the scoped release name, not signed binary download URLs. Upload does not assign recipients. A separate tester-delivery job/environment/flag grants access to the approved group only after distinct approval. No upload, release access or invitations were performed. [App Distribution overview](https://firebase.google.com/docs/app-distribution) and [REST API](https://firebase.google.com/docs/reference/app-distribution/rest).

## Missing setup and approvals

App Distribution API is enabled. The groups read returned 404, so initialization/group existence is not claimed verified. The owner must review the app's App Distribution Get started state in the Firebase console before any approved first upload. Proposed private group alias is misbar-students, with no member emails stored in Git. Do not create it, add testers or send invitations without approval.

Create a dedicated distributor identity with App Distribution permissions only in the Firebase project. It must not get Firebase Auth administration, Firestore data access or backend runtime secrets. Review any additional quota-project permission explicitly if required. Store the existing key in Secret Manager only after the owner separately approves that handling; grant access to that secret alone. Set its explicit version, not an unreviewed replacement. See deployment/iam-plan.json.

Required future non-secret settings: MISBAR_ANDROID_WIF_PROVIDER, MISBAR_ANDROID_DISTRIBUTOR, MISBAR_ANDROID_SIGNING_SECRET and MISBAR_ANDROID_SIGNING_SECRET_VERSION. MISBAR_ANDROID_DISTRIBUTION_ENABLED gates upload; MISBAR_TESTER_DELIVERY_ENABLED separately gates recipients. policy.json has corresponding false flags. Protected environments are misbar-android-upload and misbar-tester-delivery. No service-account key belongs in GitHub.

## Wireless access is not complete

The current physical-phone URL uses 127.0.0.1 and USB forwarding. Upload/build jobs deliberately reject this as distribution-ready. mobile_connectivity_verified remains false and no wireless URL is configured. Complete the separately approved design and end-to-end checks in BACKEND_CONNECTIVITY.md before activation. Do not claim that App Distribution makes the backend reachable without USB.

## Tester instructions after approval

The owner approves tester email addresses privately and assigns them to the private group. An invited tester opens the official Firebase invitation with the approved Google account, accepts access, follows the official Android App Tester/install instructions, and installs the approved release. Keep package/signature compatibility; the tester should not uninstall or clear storage to resolve an update error. Existing Firebase sign-in behavior is unchanged. An invitation/notification is a deliberate owner-approved delivery action, not part of local preparation.

## Android rollback

An older APK may be rejected as a version-code downgrade. Preserve app data and signing identity by preparing the previously approved source behavior as a new reviewed build with a higher version code and the same key, then explicitly approve its upload/delivery. Do not uninstall, clear storage, replace keys or force a downgrade. Keep prior approved source/build receipts and owner-controlled APK backups outside Git; Firebase retention is not the only rollback record.
