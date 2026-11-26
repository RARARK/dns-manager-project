import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 5173,
    // Windows 호스트 -> 리눅스 컨테이너 바인드 마운트에서는 inotify 이벤트가
    // 전달되지 않아 HMR 이 동작하지 않는다. 폴링으로 감지한다.
    watch: { usePolling: true, interval: 300 },
    // Vite 는 기본적으로 localhost 외의 Host 헤더를 거부한다("Blocked request").
    // 다른 PC 에서 호스트명으로 접속하는 시연을 막으므로 허용한다.
    // 개발 서버이므로 BIND_ADDR 로 노출 범위를 통제하는 쪽을 택한다.
    allowedHosts: true,
  },
});
