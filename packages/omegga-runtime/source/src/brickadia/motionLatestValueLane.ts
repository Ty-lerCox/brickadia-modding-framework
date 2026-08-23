export type MotionLaneOfferResult = {
  sent: boolean;
  queued: boolean;
  coalesced: boolean;
};

/**
 * Keeps at most one unsent motion frame while a socket is backpressured.
 * Command and tunnel traffic do not use this lane.
 */
export default class MotionLatestValueLane {
  #backpressured = false;
  #pendingPayload: string | null = null;

  get hasPendingPayload() {
    return this.#pendingPayload !== null;
  }

  offer(
    payload: string,
    externallyBackpressured: boolean,
    write: (payload: string) => boolean,
  ): MotionLaneOfferResult {
    if (
      this.#backpressured ||
      externallyBackpressured ||
      this.#pendingPayload !== null
    ) {
      const coalesced = this.#pendingPayload !== null;
      this.#pendingPayload = payload;
      return { sent: false, queued: true, coalesced };
    }

    this.#backpressured = !write(payload);
    return { sent: true, queued: false, coalesced: false };
  }

  drain(write: (payload: string) => boolean): MotionLaneOfferResult {
    this.#backpressured = false;
    if (this.#pendingPayload === null) {
      return { sent: false, queued: false, coalesced: false };
    }

    const payload = this.#pendingPayload;
    this.#pendingPayload = null;
    this.#backpressured = !write(payload);
    return { sent: true, queued: false, coalesced: false };
  }

  clear() {
    const droppedPendingPayload = this.#pendingPayload !== null;
    this.#pendingPayload = null;
    this.#backpressured = false;
    return droppedPendingPayload;
  }
}
