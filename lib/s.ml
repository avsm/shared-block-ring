(*
 * Copyright (C) 2013 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

module type BLOCK = V1.BLOCK
  with type 'a io = 'a Lwt.t
  and type page_aligned_buffer = Cstruct.t

module type COMPARABLE = sig
  type t
  (** An item with a total ordering *)

  val compare: t -> t -> [ `LessThan | `Equal | `GreaterThan ]
  (** Compare two items *)
end

module type CSTRUCTABLE = sig
  type t
  (** Something that can be read from and written to a Cstruct.t *)

  val to_cstruct: t -> Cstruct.t
  val of_cstruct: Cstruct.t -> t option
end

module type LOG = sig
  val debug : ('a, unit, string, unit) format4 -> 'a
  val info  : ('a, unit, string, unit) format4 -> 'a
  val error : ('a, unit, string, unit) format4 -> 'a
end

module type RING = sig
  type t
  (* A ring containing variable-sized messages *)

  type disk
  (* A block device *)

  type item
  (* A message on the ring *)

  val attach: disk:disk -> unit -> [ `Ok of t | `Error of string ] Lwt.t
  (** [attach blockdevice] attaches to a previously-created shared ring on top
      of [blockdevice]. *)

  val detach: t -> unit Lwt.t
  (** [detach t] frees all resources associated with [t]. Attempts to use [t]
      after a detach will result in an [`Error _] *)

  val state: t -> [ `Ok of [ `Running | `Suspended ] | `Error of string ] Lwt.t
  (** [state t ()] queries the current state of the ring. If the result is
      `Suspended then the producer has acknowledged and will nolonger produce
      items. Clients which support suspend/resume should arrange to call this
      function periodically. *)

  type position with sexp_of
  (** The position within a stream *)

  include COMPARABLE with type t := position

  val advance: t:t -> position:position -> unit -> [ `Ok of unit | `Error of string ] Lwt.t
  (** [advance t position] exposes the item associated with [position] to
      the Consumer so it can be [pop]ped. *)
end

module type PRODUCER = sig
  include RING

  val create: disk:disk -> unit -> [ `Ok of unit | `Error of string ] Lwt.t
  (** [create blockdevice] initialises a shared ring on top of [blockdevice]
      where we will be able to [push] variable-sized items. *)

  val push: t:t -> item:item -> unit -> [ `Ok of position | `TooBig | `Suspend | `Retry | `Error of string ] Lwt.t
  (** [push t item] pushes [item] onto the ring [t] but doesn't expose it to
      the Consumer.
      [`Ok position] means the update has been safely written to the block device
      and can be exposed to the Consumer by calling [advance position].
      [`TooBig] means the item is too big for the ring: we adopt the convention
      that items must be written to the ring in one go
      [`Suspend] means that the consumer has requested that no more items
      be pushed onto the queue temporarily
      [`Retry] means that the item should fit but there is temporarily not
      enough space in the ring. The client should retry later. *)
end

module type CONSUMER = sig
  include RING

  val suspend: t -> [ `Ok of unit | `Error of string ] Lwt.t
  (** [suspend t] signals that the producer should stop pushing items.
      Note this function returns before the producer has acknowledged. *)

  val resume: t -> [ `Ok of unit | `Error of string ] Lwt.t
  (** [resume t] signals that a producer may again start pushing items.
      This call does not wait for an acknowledgement from the producer.
      Note it is not an error to resume an already-resumed queue. *)

  val pop: t:t -> ?from:position -> unit -> [ `Ok of position * item | `Retry | `Error of string ] Lwt.t
  (** [peek t ?position ()] returns a pair [(position, item)] where [item] is the
      next item on the ring after [from]. Repeated calls to [pop] will return the
      same [item].
      To indicate that the item has been processed, call [advance position].
      [`Retry] means there is no item available at the moment and the client should
      try again later. *)

  val fold: f:(item -> 'a -> 'a) -> t:t -> ?from:position -> init:'a -> unit -> [ `Ok of (position * 'a) | `Error of string ] Lwt.t
  (** [peek_all f t ?position init ()] folds [f] across all the values that can be
      immediately [peek]ed from the ring. If any of the [fold] operations fail
      then the whole operation fails. The successful result includes the final
      [position] which can be used to consume all the items at once. *)
end


module type JOURNAL = sig
  type t
  (** A journal kept on disk of work we need to perform *)

  type disk
  (** The disk where we will keep our records. This should persist over a crash. *)

  type operation
  (** An idempotent operation which we will perform at-least-once *)

  val start: disk -> (operation list -> unit Lwt.t) -> t Lwt.t
  (** Start a journal replay thread on a given disk, with the given processing
      function which will be applied at-least-once to every item in the journal. *)

  val shutdown: t -> unit Lwt.t
  (** Shut down a journal replay thread *)

  val push: t -> operation -> (unit -> unit Lwt.t) Lwt.t
  (** Append an operation to the journal. When this returns, the operation will
      be performed at-least-once before any later items are performed.
      If a client needs to wait for the operation to be completed then call
      the returned thunk and wait for the resulting thread. *)
end
