(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-input (err u104))
(define-constant err-institution-not-verified (err u105))
(define-constant err-access-denied (err u106))
(define-constant err-access-expired (err u107))

(define-map institutions
  { institution-id: uint }
  {
    name: (string-ascii 100),
    address: principal,
    verified: bool,
    created-at: uint
  }
)

(define-map credentials
  { credential-id: uint }
  {
    student-address: principal,
    institution-id: uint,
    credential-type: (string-ascii 50),
    credential-data: (string-ascii 500),
    grade: (string-ascii 10),
    issue-date: uint,
    expiry-date: (optional uint),
    verified: bool,
    revoked: bool
  }
)

(define-map student-credentials
  { student: principal, index: uint }
  { credential-id: uint }
)

(define-map student-credential-count
  { student: principal }
  { count: uint }
)

(define-map institution-admins
  { institution-id: uint, admin: principal }
  { authorized: bool }
)

(define-data-var next-institution-id uint u1)
(define-data-var next-credential-id uint u1)

(define-read-only (get-institution (institution-id uint))
  (map-get? institutions { institution-id: institution-id })
)

(define-read-only (get-credential (credential-id uint))
  (map-get? credentials { credential-id: credential-id })
)

(define-read-only (get-student-credential-count (student principal))
  (default-to { count: u0 } (map-get? student-credential-count { student: student }))
)

(define-read-only (get-student-credential-by-index (student principal) (index uint))
  (match (map-get? student-credentials { student: student, index: index })
    credential-ref (get-credential (get credential-id credential-ref))
    none
  )
)

(define-read-only (is-institution-admin (institution-id uint) (admin principal))
  (default-to false 
    (get authorized 
      (map-get? institution-admins { institution-id: institution-id, admin: admin })
    )
  )
)

(define-read-only (verify-credential (credential-id uint))
  (match (get-credential credential-id)
    credential 
    (let (
      (institution (unwrap! (get-institution (get institution-id credential)) (err err-not-found)))
    )
      (ok {
        credential: credential,
        institution: institution,
        valid: (and 
          (get verified credential)
          (not (get revoked credential))
          (get verified institution)
        )
      })
    )
    (err err-not-found)
  )
)

(define-public (register-institution (name (string-ascii 100)))
  (let (
    (institution-id (var-get next-institution-id))
  )
    (asserts! (> (len name) u0) err-invalid-input)
    (map-set institutions
      { institution-id: institution-id }
      {
        name: name,
        address: tx-sender,
        verified: false,
        created-at: stacks-block-height
      }
    )
    (map-set institution-admins
      { institution-id: institution-id, admin: tx-sender }
      { authorized: true }
    )
    (var-set next-institution-id (+ institution-id u1))
    (ok institution-id)
  )
)

(define-public (verify-institution (institution-id uint))
  (let (
    (institution (unwrap! (get-institution institution-id) err-not-found))
  )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set institutions
      { institution-id: institution-id }
      (merge institution { verified: true })
    )
    (ok true)
  )
)

(define-public (add-institution-admin (institution-id uint) (admin principal))
  (let (
    (institution (unwrap! (get-institution institution-id) err-not-found))
  )
    (asserts! (or 
      (is-eq tx-sender (get address institution))
      (is-institution-admin institution-id tx-sender)
    ) err-unauthorized)
    (map-set institution-admins
      { institution-id: institution-id, admin: admin }
      { authorized: true }
    )
    (ok true)
  )
)

(define-public (issue-credential 
  (student-address principal)
  (institution-id uint)
  (credential-type (string-ascii 50))
  (credential-data (string-ascii 500))
  (grade (string-ascii 10))
  (expiry-date (optional uint))
)
  (let (
    (credential-id (var-get next-credential-id))
    (institution (unwrap! (get-institution institution-id) err-not-found))
    (student-count (get count (get-student-credential-count student-address)))
  )
    (asserts! (get verified institution) err-institution-not-verified)
    (asserts! (is-institution-admin institution-id tx-sender) err-unauthorized)
    (asserts! (> (len credential-type) u0) err-invalid-input)
    (asserts! (> (len credential-data) u0) err-invalid-input)
    
    (map-set credentials
      { credential-id: credential-id }
      {
        student-address: student-address,
        institution-id: institution-id,
        credential-type: credential-type,
        credential-data: credential-data,
        grade: grade,
        issue-date: stacks-block-height,
        expiry-date: expiry-date,
        verified: true,
        revoked: false
      }
    )
    
    (map-set student-credentials
      { student: student-address, index: student-count }
      { credential-id: credential-id }
    )
    
    (map-set student-credential-count
      { student: student-address }
      { count: (+ student-count u1) }
    )
    
    (var-set next-credential-id (+ credential-id u1))
    (ok credential-id)
  )
)

(define-public (revoke-credential (credential-id uint))
  (let (
    (credential (unwrap! (get-credential credential-id) err-not-found))
  )
    (asserts! (is-institution-admin (get institution-id credential) tx-sender) err-unauthorized)
    (map-set credentials
      { credential-id: credential-id }
      (merge credential { revoked: true })
    )
    (ok true)
  )
)

(define-public (transfer-credential-ownership (credential-id uint) (new-owner principal))
  (let (
    (credential (unwrap! (get-credential credential-id) err-not-found))
    (old-owner (get student-address credential))
    (old-count (get count (get-student-credential-count old-owner)))
    (new-count (get count (get-student-credential-count new-owner)))
  )
    (asserts! (is-eq tx-sender old-owner) err-unauthorized)
    (asserts! (not (get revoked credential)) err-unauthorized)
    
    (map-set credentials
      { credential-id: credential-id }
      (merge credential { student-address: new-owner })
    )
    
    (map-set student-credentials
      { student: new-owner, index: new-count }
      { credential-id: credential-id }
    )
    
    (map-set student-credential-count
      { student: new-owner }
      { count: (+ new-count u1) }
    )
    
    (ok true)
  )
)

(define-read-only (get-all-student-credentials (student principal))
  (let (
    (count (get count (get-student-credential-count student)))
  )
    (map get-student-credential-by-index-helper (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9))
  )
)

(define-private (get-student-credential-by-index-helper (index uint))
  (get-student-credential-by-index tx-sender index)
)

(define-map credential-access-grants
  { credential-id: uint, grantee: principal }
  {
    granted-by: principal,
    granted-at: uint,
    expires-at: uint,
    access-level: (string-ascii 20),
    active: bool
  }
)

(define-map grantee-access-count
  { grantee: principal }
  { count: uint }
)

(define-data-var next-access-id uint u1)

(define-read-only (get-access-grant (credential-id uint) (grantee principal))
  (map-get? credential-access-grants { credential-id: credential-id, grantee: grantee })
)

(define-read-only (can-access-credential (credential-id uint) (accessor principal))
  (let (
    (credential (unwrap! (get-credential credential-id) (err err-not-found)))
    (grant (get-access-grant credential-id accessor))
  )
    (if (is-eq accessor (get student-address credential))
      (ok true)
      (match grant
        access-data
        (ok (and 
          (get active access-data)
          (< stacks-block-height (get expires-at access-data))
        ))
        (ok false)
      )
    )
  )
)

(define-public (grant-credential-access 
  (credential-id uint) 
  (grantee principal) 
  (access-level (string-ascii 20))
  (duration-blocks uint)
)
  (let (
    (credential (unwrap! (get-credential credential-id) err-not-found))
    (expires-at (+ stacks-block-height duration-blocks))
    (grantee-count (get count (default-to { count: u0 } (map-get? grantee-access-count { grantee: grantee }))))
  )
    (asserts! (is-eq tx-sender (get student-address credential)) err-unauthorized)
    (asserts! (not (get revoked credential)) err-unauthorized)
    (asserts! (> duration-blocks u0) err-invalid-input)
    
    (map-set credential-access-grants
      { credential-id: credential-id, grantee: grantee }
      {
        granted-by: tx-sender,
        granted-at: stacks-block-height,
        expires-at: expires-at,
        access-level: access-level,
        active: true
      }
    )
    
    (map-set grantee-access-count
      { grantee: grantee }
      { count: (+ grantee-count u1) }
    )
    
    (ok true)
  )
)

(define-public (revoke-credential-access (credential-id uint) (grantee principal))
  (let (
    (credential (unwrap! (get-credential credential-id) err-not-found))
    (grant (unwrap! (get-access-grant credential-id grantee) err-not-found))
  )
    (asserts! (is-eq tx-sender (get student-address credential)) err-unauthorized)
    
    (map-set credential-access-grants
      { credential-id: credential-id, grantee: grantee }
      (merge grant { active: false })
    )
    
    (ok true)
  )
)

(define-read-only (access-credential-with-permission (credential-id uint))
  (let (
    (credential (get-credential credential-id))
    (access-check (can-access-credential credential-id tx-sender))
  )
    (match credential
      cred
      (match access-check
        has-access
        (if has-access
          (ok cred)
          (err err-access-denied)
        )
        error-val
        (err err-access-denied)
      )
      (err err-not-found)
    )
  )
)

(define-map institution-metrics
  { institution-id: uint }
  {
    total-issued: uint,
    total-revoked: uint,
    first-credential-date: uint,
    last-activity: uint
  }
)

(define-map institution-ratings
  { institution-id: uint, rater: principal }
  {
    score: uint,
    comment: (string-ascii 200),
    rated-at: uint
  }
)

(define-map institution-rating-summary
  { institution-id: uint }
  {
    total-ratings: uint,
    score-sum: uint,
    average-score: uint
  }
)

(define-read-only (get-institution-metrics (institution-id uint))
  (default-to 
    { total-issued: u0, total-revoked: u0, first-credential-date: u0, last-activity: u0 }
    (map-get? institution-metrics { institution-id: institution-id })
  )
)

(define-read-only (get-institution-reputation (institution-id uint))
  (let (
    (metrics (get-institution-metrics institution-id))
    (rating-summary (default-to 
      { total-ratings: u0, score-sum: u0, average-score: u0 }
      (map-get? institution-rating-summary { institution-id: institution-id })
    ))
    (revocation-rate (if (> (get total-issued metrics) u0)
      (/ (* (get total-revoked metrics) u100) (get total-issued metrics))
      u0
    ))
  )
    (ok {
      metrics: metrics,
      revocation-rate: revocation-rate,
      community-score: (get average-score rating-summary),
      total-community-ratings: (get total-ratings rating-summary),
      reputation-score: (calculate-reputation-score metrics rating-summary)
    })
  )
)

(define-read-only (get-institution-rating (institution-id uint) (rater principal))
  (map-get? institution-ratings { institution-id: institution-id, rater: rater })
)

(define-private (calculate-reputation-score 
  (metrics { total-issued: uint, total-revoked: uint, first-credential-date: uint, last-activity: uint })
  (rating-summary { total-ratings: uint, score-sum: uint, average-score: uint })
)
  (let (
    (activity-score (if (< (get total-issued metrics) u40) (get total-issued metrics) u40))
    (revocation-penalty (if (> (get total-issued metrics) u0)
      (/ (* (get total-revoked metrics) u30) (get total-issued metrics))
      u0
    ))
    (quality-score (if (> (get total-issued metrics) u0)
      (- u30 (if (< revocation-penalty u30) revocation-penalty u30))
      u0
    ))
    (community-score (if (> (get total-ratings rating-summary) u0)
      (/ (* (get average-score rating-summary) u30) u100)
      u15
    ))
  )
    (+ activity-score quality-score community-score)
  )
)

(define-public (rate-institution (institution-id uint) (score uint) (comment (string-ascii 200)))
  (let (
    (institution (unwrap! (get-institution institution-id) err-not-found))
    (existing-rating (get-institution-rating institution-id tx-sender))
    (current-summary (default-to 
      { total-ratings: u0, score-sum: u0, average-score: u0 }
      (map-get? institution-rating-summary { institution-id: institution-id })
    ))
  )
    (asserts! (get verified institution) err-institution-not-verified)
    (asserts! (and (>= score u1) (<= score u100)) err-invalid-input)
    (asserts! (> (len comment) u0) err-invalid-input)
    
    (let (
      (new-total (if (is-some existing-rating) 
        (get total-ratings current-summary)
        (+ (get total-ratings current-summary) u1)
      ))
      (score-adjustment (match existing-rating
        old-rating (- score (get score old-rating))
        score
      ))
      (new-score-sum (+ (get score-sum current-summary) score-adjustment))
      (new-average (if (> new-total u0) (/ new-score-sum new-total) u0))
    )
      (map-set institution-ratings
        { institution-id: institution-id, rater: tx-sender }
        { score: score, comment: comment, rated-at: stacks-block-height }
      )
      
      (map-set institution-rating-summary
        { institution-id: institution-id }
        { total-ratings: new-total, score-sum: new-score-sum, average-score: new-average }
      )
      
      (ok true)
    )
  )
)

(define-private (update-institution-metrics-on-issue (institution-id uint))
  (let (
    (current-metrics (get-institution-metrics institution-id))
    (new-total-issued (+ (get total-issued current-metrics) u1))
    (first-date (if (is-eq (get first-credential-date current-metrics) u0)
      stacks-block-height
      (get first-credential-date current-metrics)
    ))
  )
    (map-set institution-metrics
      { institution-id: institution-id }
      {
        total-issued: new-total-issued,
        total-revoked: (get total-revoked current-metrics),
        first-credential-date: first-date,
        last-activity: stacks-block-height
      }
    )
  )
)

(define-private (update-institution-metrics-on-revoke (institution-id uint))
  (let (
    (current-metrics (get-institution-metrics institution-id))
  )
    (map-set institution-metrics
      { institution-id: institution-id }
      (merge current-metrics 
        { 
          total-revoked: (+ (get total-revoked current-metrics) u1),
          last-activity: stacks-block-height
        }
      )
    )
  )
)

(define-map credential-stacks
  { stack-id: uint }
  {
    owner: principal,
    title: (string-ascii 100),
    description: (string-ascii 300),
    domain: (string-ascii 50),
    created-at: uint,
    is-public: bool,
    credential-count: uint
  }
)

(define-map stack-credentials
  { stack-id: uint, credential-id: uint }
  { 
    added-at: uint,
    weight: uint
  }
)

(define-map user-stack-count
  { owner: principal }
  { count: uint }
)

(define-data-var next-stack-id uint u1)

(define-read-only (get-credential-stack (stack-id uint))
  (map-get? credential-stacks { stack-id: stack-id })
)

(define-read-only (is-credential-in-stack (stack-id uint) (credential-id uint))
  (is-some (map-get? stack-credentials { stack-id: stack-id, credential-id: credential-id }))
)

(define-read-only (get-user-stack-count (owner principal))
  (default-to { count: u0 } (map-get? user-stack-count { owner: owner }))
)

(define-read-only (validate-stack-completeness (stack-id uint))
  (match (get-credential-stack stack-id)
    stack
    (ok {
      total-credentials: (get credential-count stack),
      all-valid: (>= (get credential-count stack) u2),
      owner-verified: (is-eq (get owner stack) tx-sender)
    })
    (err err-not-found)
  )
)

(define-public (create-credential-stack 
  (title (string-ascii 100))
  (description (string-ascii 300))
  (domain (string-ascii 50))
  (is-public bool)
)
  (let (
    (stack-id (var-get next-stack-id))
    (user-count (get count (get-user-stack-count tx-sender)))
  )
    (asserts! (> (len title) u0) err-invalid-input)
    (asserts! (> (len domain) u0) err-invalid-input)
    
    (map-set credential-stacks
      { stack-id: stack-id }
      {
        owner: tx-sender,
        title: title,
        description: description,
        domain: domain,
        created-at: stacks-block-height,
        is-public: is-public,
        credential-count: u0
      }
    )
    
    (map-set user-stack-count
      { owner: tx-sender }
      { count: (+ user-count u1) }
    )
    
    (var-set next-stack-id (+ stack-id u1))
    (ok stack-id)
  )
)

(define-public (add-credential-to-stack (stack-id uint) (credential-id uint) (weight uint))
  (let (
    (stack (unwrap! (get-credential-stack stack-id) err-not-found))
    (credential (unwrap! (get-credential credential-id) err-not-found))
  )
    (asserts! (is-eq tx-sender (get owner stack)) err-unauthorized)
    (asserts! (is-eq tx-sender (get student-address credential)) err-unauthorized)
    (asserts! (not (is-credential-in-stack stack-id credential-id)) err-already-exists)
    (asserts! (and (>= weight u1) (<= weight u10)) err-invalid-input)
    
    (map-set stack-credentials
      { stack-id: stack-id, credential-id: credential-id }
      { added-at: stacks-block-height, weight: weight }
    )
    
    (map-set credential-stacks
      { stack-id: stack-id }
      (merge stack { credential-count: (+ (get credential-count stack) u1) })
    )
    
    (ok true)
  )
)

(define-public (remove-credential-from-stack (stack-id uint) (credential-id uint))
  (let (
    (stack (unwrap! (get-credential-stack stack-id) err-not-found))
  )
    (asserts! (is-eq tx-sender (get owner stack)) err-unauthorized)
    (asserts! (is-credential-in-stack stack-id credential-id) err-not-found)
    
    (map-delete stack-credentials { stack-id: stack-id, credential-id: credential-id })
    
    (map-set credential-stacks
      { stack-id: stack-id }
      (merge stack { credential-count: (- (get credential-count stack) u1) })
    )
    
    (ok true)
  )
)