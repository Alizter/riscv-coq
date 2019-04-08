Require Import Coq.ZArith.ZArith.
Require Import Coq.Logic.FunctionalExtensionality.
Require Import Coq.Logic.PropExtensionality.
Require Import riscv.Utility.Monads. Import OStateNDOperations.
Require Import riscv.Utility.MonadNotations.
Require Import riscv.Spec.Decode.
Require Import riscv.Spec.Machine.
Require Import riscv.Utility.Utility.
Require Import riscv.Spec.Primitives.
Require Import Coq.Lists.List. Import ListNotations.
Require Export riscv.Utility.MMIOTrace.
Require Export riscv.Platform.RiscvMachine.
Require Import coqutil.Z.Lia.
Require Import coqutil.Map.Interface.
Require Import coqutil.Tactics.Tactics.
Require riscv.Platform.Minimal.

Local Open Scope Z_scope.
Local Open Scope bool_scope.

Section Riscv.

  Context {W: Words}.
  Context {Mem: map.map word byte}.
  Context {Registers: map.map Register word}.

  Local Notation RiscvMachineL := (RiscvMachine Register MMIOAction).

  Definition signedByteTupleToReg{n: nat}(v: HList.tuple byte n): word :=
    word.of_Z (BitOps.signExtend (8 * Z.of_nat n) (LittleEndian.combine n v)).

  Definition mmioLoadEvent(addr: word){n: nat}(v: HList.tuple byte n):
    LogItem MMIOAction := ((map.empty, MMInput, [addr]), (map.empty, [signedByteTupleToReg v])).

  Definition mmioStoreEvent(addr: word){n: nat}(v: HList.tuple byte n):
    LogItem MMIOAction :=
    ((map.empty, MMOutput, [addr; signedByteTupleToReg v]), (map.empty, [])).

  Definition logEvent(e: LogItem MMIOAction): OStateND RiscvMachineL unit :=
    m <- get; put (withLogItem e m).

  Definition lift{A: Type}(m: OState RiscvMachineL A): OStateND RiscvMachineL A :=
    fun s oas' => (exists s', m s = (None, s') /\ oas' = None) \/
                  (exists a s', m s = (Some a, s') /\ oas' = Some (a, s')).

  Definition loadN(n: nat)(a: word): OStateND RiscvMachineL (HList.tuple byte n) :=
    mach <- get;
    match Memory.load_bytes n mach.(getMem) a with
    | Some v => lift (Minimal.loadN n a)
    | None =>
      (* if any of the n addresses is not present in the memory, we perform an MMIO load event: *)
      inp <- arbitrary (HList.tuple byte n);
      logEvent (mmioLoadEvent a inp);;
      Return inp
    end.

  Definition storeN(n: nat)(a: word)(v: HList.tuple byte n): OStateND RiscvMachineL unit :=
    mach <- get;
    match Memory.store_bytes n mach.(getMem) a v with
    | Some m => lift (Minimal.storeN n a v)
    | None =>
      (* if any of the n addresses is not present in the memory, we perform an MMIO store event: *)
      logEvent (mmioStoreEvent a v)
    end.

  Definition isNone{T: Type}(o: option T) :=
    match o with
    | Some _ => false
    | None => true
    end.

  Instance IsRiscvMachineL: RiscvProgram (OStateND RiscvMachineL) word :=  {
      getRegister reg :=
        mach <- get;
        if (0 <? reg) && (reg <? 32) && (isNone (map.get mach.(getRegs) reg)) then
          arbitrary word
        else
          lift (getRegister reg);

      setRegister reg v := lift (setRegister reg v);

      getPC := lift getPC;

      setPC newPC := lift (setPC newPC);

      loadByte   kind := loadN 1;
      loadHalf   kind := loadN 2;
      loadWord   kind := loadN 4;
      loadDouble kind := loadN 8;

      storeByte   kind := storeN 1;
      storeHalf   kind := storeN 2;
      storeWord   kind := storeN 4;
      storeDouble kind := storeN 8;

      step := lift step;

      raiseExceptionWithInfo{A: Type} isInterrupt exceptionCode info :=
        lift (raiseExceptionWithInfo isInterrupt exceptionCode info);
  }.

  Arguments Memory.load_bytes: simpl never.
  Arguments Memory.store_bytes: simpl never.

  Lemma not_load_fails_but_store_succeeds: forall {m: Mem} {addr: word} {n v m'},
      Memory.load_bytes n m addr = None ->
      Memory.store_bytes n m addr v = Some m' ->
      False.
  Proof.
    intros. unfold Memory.store_bytes in *.
    rewrite H in H0.
    discriminate.
  Qed.

  Lemma not_store_fails_but_load_succeeds: forall {m: Mem} {addr: word} {n v0 v1},
      Memory.load_bytes n m addr = Some v0 ->
      Memory.store_bytes n m addr v1 = None ->
      False.
  Proof.
    intros. unfold Memory.store_bytes in *.
    rewrite H in H0.
    discriminate.
  Qed.

  Ltac t0 :=
    match goal with
       | |- _ => reflexivity
       | |- _ => progress (
                     unfold computation_satisfies, computation_with_answer_satisfies,
                            IsRiscvMachineL,
                            valid_register, Register0,
                            is_initial_register_value,
                            get, put, fail_hard,
                            arbitrary,
                            logEvent,
                            isNone,
                            ZToReg, MkMachineWidth.MachineWidth_XLEN,
                            loadN, storeN in *;
                     subst;
                     simpl in *)
       | |- _ => intro
       | |- _ => split
       | |- _ => apply functional_extensionality
       | |- _ => apply propositional_extensionality; split; intros
       | u: unit |- _ => destruct u
       | H: exists x, _ |- _ => destruct H
       | H: {_ : _ | _} |- _ => destruct H
       | H: _ /\ _ |- _ => destruct H
       | p: _ * _ |- _ => destruct p
       | |- context [ let (_, _) := ?p in _ ] => let E := fresh "E" in destruct p eqn: E
       | H: Some _ = Some _ |- _ => inversion H; clear H; subst
       | H: (_, _) = (_, _) |- _ => inversion H; clear H; subst
       | H: forall x, x = _ -> _ |- _ => specialize (H _ eq_refl)
       | H: _ && _ = true |- _ => apply andb_prop in H
       | H: _ && _ = false |- _ => apply Bool.andb_false_iff in H
       | |- _ * _ => constructor
       | |- option _ => exact None
       | |- _ => discriminate
       | |- _ => congruence
       | |- _ => solve [exfalso; bomega]
       | |- _ => solve [eauto 15]
       | H: false = ?rhs |- _ => match rhs with
                                 | false => fail 1
                                 | _ => symmetry in H
                                 end
       | |- _ => progress (rewrite? Z.ltb_nlt in *; rewrite? Z.ltb_lt in *)
       | |- _ => bomega
       | H: context[let (_, _) := ?y in _] |- _ => let E := fresh "E" in destruct y eqn: E
       | E: ?x = Some _, H: context[match ?x with _ => _ end] |- _ => rewrite E in H
       | E: ?x = Some _  |- context[match ?x with _ => _ end]      => rewrite E
       | E: ?x = None, H: context[match ?x with _ => _ end] |- _ => rewrite E in H
       | E: ?x = None  |- context[match ?x with _ => _ end]      => rewrite E
       | H: context[match ?x with _ => _ end] |- _ => let E := fresh "E" in destruct x eqn: E
       | |- context[match ?x with _ => _ end]      => let E := fresh "E" in destruct x eqn: E
       | H1: _, H2: _ |- _ => exfalso; apply (not_load_fails_but_store_succeeds H1 H2)
       | H1: _, H2: _ |- _ => exfalso; apply (not_store_fails_but_load_succeeds H1 H2)
       | |- exists a b, Some (a, b) = _ /\ _ => do 2 eexists; split; [reflexivity|]
       | |- exists a, _ = _ /\ _ => eexists; split; [reflexivity|]
       | H: ?P -> exists _, _ |- _ =>
         let N := fresh in
         assert P as N by (clear H; repeat t0);
         specialize (H N);
         clear N
       | H: _ \/ _ |- _ => destruct H
       | r: RiscvMachineL |- _ =>
         destruct r as [regs pc npc m l];
         simpl in *
       | o: option _ |- _ => destruct o
       (* introduce evars as late as possible (after all destructs), to make sure everything
          is in their scope*)
(*       | |- exists (P: ?A -> ?S -> Prop), _ =>
            let a := fresh "a" in evar (a: A);
            let s := fresh "s" in evar (s: S);
            exists (fun a0 s0 => a0 = a /\ s0 = s);
            subst a s*)
       | H1: _, H2: _ |- _ => specialize H1 with (1 := H2)
       | |- _ \/ _ => left; solve [repeat t0]
       | |- _ \/ _ => right; solve [repeat t0]
       end.

  Ltac t := repeat t0.

  Arguments LittleEndian.combine: simpl never.

  Instance MinimalMMIOPrimitivesParams: PrimitivesParams (OStateND RiscvMachineL) RiscvMachineL := {|
    Primitives.mcomp_sat := @OStateNDOperations.computation_with_answer_satisfies RiscvMachineL;

    (* any value can be found in an uninitialized register *)
    Primitives.is_initial_register_value x := True;

    Primitives.nonmem_loadByte_sat initialL addr post :=
      forall (v: w8), post v (withLogItem (mmioLoadEvent addr v) initialL);
    Primitives.nonmem_loadHalf_sat initialL addr post :=
      forall (v: w16), post v (withLogItem (mmioLoadEvent addr v) initialL);
    Primitives.nonmem_loadWord_sat initialL addr post :=
      forall (v: w32), post v (withLogItem (mmioLoadEvent addr v) initialL);
    Primitives.nonmem_loadDouble_sat initialL addr post :=
      forall (v: w64), post v (withLogItem (mmioLoadEvent addr v) initialL);

    Primitives.nonmem_storeByte_sat initialL addr v post :=
      post (withLogItem (mmioStoreEvent addr v) initialL);
    Primitives.nonmem_storeHalf_sat initialL addr v post :=
      post (withLogItem (mmioStoreEvent addr v) initialL);
    Primitives.nonmem_storeWord_sat initialL addr v post :=
      post (withLogItem (mmioStoreEvent addr v) initialL);
    Primitives.nonmem_storeDouble_sat initialL addr v post :=
      post (withLogItem (mmioStoreEvent addr v) initialL);
  |}.

  Instance MinimalMMIOSatisfiesPrimitives: Primitives MinimalMMIOPrimitivesParams.
  Proof.
    constructor. all: split.
    (* spec_Bind *)
    - t.
    - t.
      unfold OStateND in m.
      exists (fun (a: A) (middleL: RiscvMachineL) => m initialL (Some (a, middleL))).
      t.
      edestruct H as [b [? ?]]; [eauto|]. t.
    (* spec_Return *)
    - t.
    - t.
    (* spec_getRegister *)
    - t0. t0. t0. t0. t0. t0; try solve [t]. { t0; try solve [t]. t0. t0. t0. t0. t0; try solve [t]. { t0; try solve [t].

                                                                                                       edestruct (spec_getRegister (Primitives := Minimal.MinimalSatisfiesPrimitives)) as [F1 F2].

                                                                                                       clear -H1 F2. simpl in F2.
    unfold OStateOperations.computation_with_answer_satisfies in *.
                                                                                                       unfold lift in *.
                                                                                                       simpl in F1, F2.

                                                                                                       pose proof (spec_getRegister (Primitives := Minimal.MinimalSatisfiesPrimitives)) as P.
                                                                                                       edestruct (spec_getRegister (Primitives := Minimal.MinimalSatisfiesPrimitives)) as [F1 F2].                                                                                                       apply F1



as P.

                                                                                                       destruct P.


                                                                                                       apply spec_getRegister in H1.

 t0. t0. t0. t0; try solve [t]. t0. t0; try solve [t]. t0; try solve [t]. { t0.


                                                                                                                                                                          t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0. t0.

 t.
    - t.

    (* spec_setRegister *)
    (* spec_loadByte *)
    (* spec_loadHalf *)
    (* spec_loadWord *)
    (* spec_loadDouble *)
    (* spec_storeByte *)
    (* spec_storeHalf *)
    (* spec_storeWord *)
    (* spec_storeDouble *)
    (* spec_getPC *)
    (* spec_setPC *)
    (* spec_step *)


    - t.
    - t.
    -
    - t.
      unfold OStateND in m.
      exists (fun (a: A) (middleL: RiscvMachineL) => m initialL (Some (a, middleL))).
      t.
      edestruct H as [b [? ?]]; [eauto|]. t.
    - t.
    - t.
      + (edestruct H as [b [? ?]]; [eauto|]); t.
      + left. t. edestruct H as [b [? ?]]; t.
    - t.
      (edestruct H as [b [? ?]]; [eauto|]); t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.loadByte (getMem initialL) addr) eqn: F; [left|right].
      + t; match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
      + t. match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.loadHalf (getMem initialL) addr) eqn: F; [left|right].
      + t; match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
      + t. match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.loadWord (getMem initialL) addr) eqn: F; [left|right].
      + t; match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
      + t. match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.loadDouble (getMem initialL) addr) eqn: F; [left|right].
      + t; match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.
      + t. match goal with
           | |- context [?post ?inp ?mach] => specialize (H (Some (inp, mach)))
           end; t.

    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.storeByte (getMem initialL) addr v) eqn: F.
      + destruct (Memory.loadByte (getMem initialL) addr) eqn: G; [ | exfalso; t ].
       left.
        t; match goal with
        | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
        end; t.
      + destruct (Memory.loadByte (getMem initialL) addr) eqn: G; [ exfalso; t | ].
        right.
        t; match goal with
           | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.storeHalf (getMem initialL) addr v) eqn: F.
      + destruct (Memory.loadHalf (getMem initialL) addr) eqn: G; [ | exfalso; t ].
       left.
        t; match goal with
        | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
        end; t.
      + destruct (Memory.loadHalf (getMem initialL) addr) eqn: G; [ exfalso; t | ].
        right.
        t; match goal with
           | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.storeWord (getMem initialL) addr v) eqn: F.
      + destruct (Memory.loadWord (getMem initialL) addr) eqn: G; [ | exfalso; t ].
        left.
        t; match goal with
        | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
        end; t.
      + destruct (Memory.loadWord (getMem initialL) addr) eqn: G; [ exfalso; t | ].
        right.
        t; match goal with
           | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
           end; t.
    - intros. simpl in *. unfold computation_with_answer_satisfies in *.
      destruct (Memory.storeDouble (getMem initialL) addr v) eqn: F.
      + destruct (Memory.loadDouble (getMem initialL) addr) eqn: G; [ | exfalso; t ].
       left.
        t; match goal with
        | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
        end; t.
      + destruct (Memory.loadDouble (getMem initialL) addr) eqn: G; [ exfalso; t | ].
        right.
        t; match goal with
           | |- post ?inp ?mach => specialize (H (Some (inp, mach)))
           end; t.
    - t.
      (edestruct H as [b [? ?]]; [eauto|]); t.
    - t.
      (edestruct H as [b [? ?]]; [eauto|]); t.
    - t.
      (edestruct H as [b [? ?]]; [eauto|]); t.
  Qed.

End Riscv.

(* needed because defined inside a Section *)
Existing Instance IsRiscvMachineL.
Existing Instance MinimalMMIOSatisfiesPrimitives.
