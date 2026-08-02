"use client";

import Image from "next/image";
import { useEffect, useRef, useState } from "react";
import styles from "./page.module.css";

const reducedMotionQuery = "(prefers-reduced-motion: reduce)";

type MotionPreference = "pending" | "allow" | "reduce";

export function ProductDemo() {
  const containerRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const [motionPreference, setMotionPreference] =
    useState<MotionPreference>("pending");
  const [isVisible, setIsVisible] = useState(false);
  const [isPageVisible, setIsPageVisible] = useState(true);
  const [pausedByUser, setPausedByUser] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);

  useEffect(() => {
    const mediaQuery = window.matchMedia(reducedMotionQuery);
    const syncPreference = () => {
      setMotionPreference(mediaQuery.matches ? "reduce" : "allow");
    };

    syncPreference();
    mediaQuery.addEventListener("change", syncPreference);

    return () => mediaQuery.removeEventListener("change", syncPreference);
  }, []);

  useEffect(() => {
    const container = containerRef.current;

    if (!container) return;

    const observer = new IntersectionObserver(
      ([entry]) => setIsVisible(entry.intersectionRatio >= 0.35),
      { threshold: 0.35 },
    );

    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const syncPageVisibility = () => {
      setIsPageVisible(document.visibilityState === "visible");
    };

    syncPageVisibility();
    document.addEventListener("visibilitychange", syncPageVisibility);

    return () => document.removeEventListener("visibilitychange", syncPageVisibility);
  }, []);

  useEffect(() => {
    const video = videoRef.current;

    if (!video || motionPreference !== "allow") return;

    if (isVisible && isPageVisible && !pausedByUser) {
      void video.play().catch(() => setIsPlaying(false));
      return;
    }

    video.pause();
  }, [isPageVisible, isVisible, motionPreference, pausedByUser]);

  const togglePlayback = () => {
    const video = videoRef.current;

    if (!video) return;

    if (video.paused) {
      setPausedByUser(false);
      if (!isVisible || !isPageVisible) return;
      void video.play().catch(() => setIsPlaying(false));
      return;
    }

    setPausedByUser(true);
    video.pause();
  };

  const showVideo = motionPreference === "allow";

  return (
    <div ref={containerRef} className={styles.demoMedia}>
      <Image
        src="/product/focus-tracker-running.webp"
        alt={
          showVideo
            ? ""
            : "Focus Tracker with Shape the launch narrative selected and a 25 minute focus block ready to start"
        }
        width={1770}
        height={1140}
        sizes="(max-width: 700px) calc(100vw - 36px), (max-width: 1280px) calc(100vw - 68px), 1262px"
        preload
        className={styles.demoPoster}
      />

      {showVideo ? (
        <>
          <video
            ref={videoRef}
            className={styles.productVideo}
            muted
            loop
            playsInline
            preload="metadata"
            poster="/product/focus-tracker-running.webp"
            aria-label="A silent Focus Tracker demo: start a focus block, pause and resume the live timer, then record the elapsed time"
            onPlaying={() => setIsPlaying(true)}
            onPause={() => setIsPlaying(false)}
          >
            <source src="/product/focus-tracker-demo.mp4" type="video/mp4" />
          </video>

          <button
            className={styles.videoControl}
            type="button"
            onClick={togglePlayback}
            aria-label={isPlaying ? "Pause product demo" : "Play product demo"}
          >
            <svg aria-hidden="true" viewBox="0 0 16 16" width="14" height="14">
              {isPlaying ? (
                <path d="M4.5 3.25v9.5M11.5 3.25v9.5" />
              ) : (
                <path d="m5 3.25 7 4.75-7 4.75Z" />
              )}
            </svg>
            <span>{isPlaying ? "Pause" : "Play"}</span>
          </button>
        </>
      ) : null}
    </div>
  );
}
