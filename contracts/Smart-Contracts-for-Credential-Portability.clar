(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-input (err u104))
(define-constant err-institution-not-verified (err u105))

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
