import Std

set_option autoImplicit false

namespace ResearchExchangeBridge.Encoding

/-- Exact encoding of UTF-8 bytes, not a cryptographic hash. The empty list is
zero; every byte is a nonzero base-257 digit. -/
def bytes : List UInt8 → Nat
  | [] => 0
  | b :: rest => b.toNat + 1 + 257 * bytes rest

theorem bytes_injective (xs ys : List UInt8) (h : bytes xs = bytes ys) : xs = ys := by
  induction xs generalizing ys with
  | nil =>
    cases ys with
    | nil => rfl
    | cons y ys => simp only [bytes] at h; omega
  | cons x xs ih =>
    cases ys with
    | nil => simp only [bytes] at h; omega
    | cons y ys =>
      have hx := x.toNat_lt
      have hy := y.toNat_lt
      simp only [bytes] at h
      have he : x.toNat = y.toNat := by omega
      have ht : bytes xs = bytes ys := by omega
      simp only [List.cons.injEq]
      exact ⟨UInt8.toNat_inj.mp he, ih ys ht⟩

def text (s : String) : Nat := bytes s.toByteArray.data.toList

theorem text_injective (s t : String) (h : text s = text t) : s = t := by
  exact String.toByteArray_inj.mp (ByteArray.ext (Array.ext' (bytes_injective _ _ h)))

/-- Base-258 digits permit an out-of-byte-range separator, 256. -/
def digits : List (Fin 257) → Nat
  | [] => 0
  | d :: rest => d.val + 1 + 258 * digits rest

theorem digits_injective (xs ys : List (Fin 257)) (h : digits xs = digits ys) : xs = ys := by
  induction xs generalizing ys with
  | nil =>
    cases ys with
    | nil => rfl
    | cons y ys => simp only [digits] at h; omega
  | cons x xs ih =>
    cases ys with
    | nil => simp only [digits] at h; omega
    | cons y ys =>
      have hx := x.isLt
      have hy := y.isLt
      simp only [digits] at h
      have he : x.val = y.val := by omega
      have ht : digits xs = digits ys := by omega
      simp only [List.cons.injEq]
      exact ⟨Fin.ext he, ih ys ht⟩

def byteDigit (b : UInt8) : Fin 257 := ⟨b.toNat, by have h := b.toNat_lt; omega⟩
def separator : Fin 257 := ⟨256, by decide⟩

def frame : List (List UInt8) → List (Fin 257)
  | [] => []
  | field :: fields => field.map byteDigit ++ separator :: frame fields

/-- An executable left inverse for framed fields. Malformed trailing data is
retained as a final field; only the left-inverse theorem is used for injection. -/
def unframe : List (Fin 257) → List (List Nat)
  | [] => []
  | d :: rest =>
    if d.val = 256 then [] :: unframe rest
    else match unframe rest with
      | [] => [[d.val]]
      | field :: fields => (d.val :: field) :: fields

theorem unframe_field (field : List UInt8) (rest : List (Fin 257)) :
    unframe (field.map byteDigit ++ separator :: rest) =
      field.map UInt8.toNat :: unframe rest := by
  induction field with
  | nil => rfl
  | cons b bs ih =>
    have hb := b.toNat_lt
    have hn : b.toNat ≠ 256 := by omega
    simp [unframe, byteDigit, hn, ih]

theorem unframe_frame (fields : List (List UInt8)) :
    unframe (frame fields) = fields.map (List.map UInt8.toNat) := by
  induction fields with
  | nil => rfl
  | cons f fs ih => simp [frame, unframe_field, ih]

theorem map_bytes_injective (xs ys : List UInt8)
    (h : xs.map UInt8.toNat = ys.map UInt8.toNat) : xs = ys := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp_all
  | cons x xs ih =>
    cases ys with
    | nil => simp_all
    | cons y ys =>
      simp only [List.map_cons, List.cons.injEq] at h
      simp only [List.cons.injEq]
      exact ⟨UInt8.toNat_inj.mp h.1, ih ys h.2⟩

theorem frame_injective (xs ys : List (List UInt8)) (h : frame xs = frame ys) : xs = ys := by
  have decoded := congrArg unframe h
  simp only [unframe_frame] at decoded
  clear h
  induction xs generalizing ys with
  | nil => cases ys <;> simp_all
  | cons x xs ih =>
    cases ys with
    | nil => simp_all
    | cons y ys =>
      simp only [List.map_cons, List.cons.injEq] at decoded
      simp only [List.cons.injEq]
      exact ⟨map_bytes_injective _ _ decoded.1, ih ys decoded.2⟩

def fields (xs : List String) : Nat :=
  digits (frame (xs.map (fun s => s.toByteArray.data.toList)))

theorem fields_injective (xs ys : List String) (h : fields xs = fields ys) : xs = ys := by
  have encoded := frame_injective _ _ (digits_injective _ _ h)
  clear h
  induction xs generalizing ys with
  | nil => cases ys <;> simp_all
  | cons x xs ih =>
    cases ys with
    | nil => simp_all
    | cons y ys =>
      simp only [List.map_cons, List.cons.injEq] at encoded
      have he : x = y :=
        String.toByteArray_inj.mp (ByteArray.ext (Array.ext' encoded.1))
      simp only [List.cons.injEq]
      exact ⟨he, ih ys encoded.2⟩

end ResearchExchangeBridge.Encoding
