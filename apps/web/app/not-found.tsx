import Link from "next/link";
import styles from "./not-found.module.css";

export default function NotFound() {
  return (
    <main className={styles.main}>
      <p>Page not found</p>
      <h1>This block does not exist.</h1>
      <Link href="/">Return to Focus Tracker</Link>
    </main>
  );
}
