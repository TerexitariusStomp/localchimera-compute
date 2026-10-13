// app/awake.ts — keep the screen on while something is under way.
//
// `keepAwake()` asks the browser's wake lock and returns the way to let it go. The browser drops the lock when the page
// is hidden, so it is taken again on return for as long as it is wanted. A browser with no wake lock, or one that
// refuses, leaves the screen to its own timeout: nothing here fails.
export function keepAwake() {
    let lock = null, wanted = true;
    const take = async () => {
        if (!wanted || (lock && !lock.released))
            return;
        try {
            const l = (await navigator.wakeLock?.request("screen")) ?? null;
            if (wanted)
                lock = l;
            else
                void l?.release(); // let go before it came
        }
        catch {
            lock = null;
        }
    };
    const back = () => { if (document.visibilityState === "visible")
        void take(); };
    document.addEventListener("visibilitychange", back);
    void take();
    return () => {
        wanted = false;
        document.removeEventListener("visibilitychange", back);
        void lock?.release();
        lock = null;
    };
}
