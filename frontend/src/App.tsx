import { useEffect, useState } from "react";
import { Badge, Container, Group, Loader, Stack, Tabs, Text, Title, Tooltip } from "@mantine/core";
import { IconHistory, IconListDetails, IconRouter, IconSearch } from "@tabler/icons-react";
import RecordsPanel from "./components/RecordsPanel";
import QueryTestPanel from "./components/QueryTestPanel";
import AuditLogPanel from "./components/AuditLogPanel";
import ForwardingPanel from "./components/ForwardingPanel";
import { api } from "./api";
import { useDnsSync } from "./useDnsSync";

export default function App() {
  const [tab, setTab] = useState<string | null>("records");
  const [upstreams, setUpstreams] = useState<string[]>([]);
  const { phase, elapsedMs, status, markChanged } = useDnsSync();

  // 헤더 배지는 하드코딩이 아니라 실제 적용된 설정을 보여준다.
  async function refreshUpstreams() {
    try {
      setUpstreams((await api.getForwarding()).upstreams);
    } catch {
      setUpstreams([]);
    }
  }

  useEffect(() => {
    refreshUpstreams();
  }, []);

  return (
    <Container size="lg" py="xl">
      <Stack gap="lg">
        <Group justify="space-between" align="flex-end">
          <div>
            <Title order={1}>DNS Manager</Title>
            <Text c="dimmed" size="sm">
              CoreDNS 로컬 존 관리 콘솔
            </Text>
          </div>
          <Group gap="xs">
            <Tooltip
              multiline
              w={280}
              label={
                phase === "pending"
                  ? "존 파일은 이미 바뀌었고, CoreDNS가 아직 새 설정을 읽지 않았습니다. 보통 2초 안에 반영됩니다."
                  : phase === "unreachable"
                    ? `CoreDNS에 질의할 수 없습니다. 저장은 되지만 DNS 응답은 바뀌지 않습니다. ${status?.detail ?? ""}`
                    : `존 파일 serial ${status?.zone_serial ?? "?"} = CoreDNS가 응답하는 serial ${status?.served_serial ?? "?"}`
              }
            >
              <Badge
                size="lg"
                variant={phase === "synced" ? "light" : "filled"}
                color={phase === "synced" ? "teal" : phase === "pending" ? "yellow" : phase === "unreachable" ? "red" : "gray"}
                leftSection={phase === "pending" ? <Loader size={10} color="dark" /> : undefined}
                style={{ cursor: "help" }}
              >
                {phase === "synced"
                  ? "DNS 반영됨"
                  : phase === "pending"
                    ? `DNS 반영 중 ${(elapsedMs / 1000).toFixed(1)}s`
                    : phase === "unreachable"
                      ? "DNS 응답 없음"
                      : "확인 중"}
              </Badge>
            </Tooltip>
            <Badge variant="light" size="lg">
              zone: lab.test
            </Badge>
            <Badge variant="light" color="gray" size="lg">
              upstream: {upstreams.length > 0 ? upstreams.join(" / ") : "…"}
            </Badge>
          </Group>
        </Group>

        {/* keepMounted 기본값(true)이면 비활성 탭의 내용까지 항상 DOM 에 그려진다.
            변경 이력 탭이 수천 행을 들고 있을 때 불필요한 부담이 된다. */}
        <Tabs value={tab} onChange={setTab} keepMounted={false}>
          <Tabs.List>
            <Tabs.Tab value="records" leftSection={<IconListDetails size={16} />}>
              레코드 관리
            </Tabs.Tab>
            <Tabs.Tab value="query" leftSection={<IconSearch size={16} />}>
              DNS 질의 테스트
            </Tabs.Tab>
            <Tabs.Tab value="forwarding" leftSection={<IconRouter size={16} />}>
              Forwarding 설정
            </Tabs.Tab>
            <Tabs.Tab value="audit" leftSection={<IconHistory size={16} />}>
              변경 이력
            </Tabs.Tab>
          </Tabs.List>

          <Tabs.Panel value="records" pt="lg" mih={640}>
            <RecordsPanel onChanged={markChanged} />
          </Tabs.Panel>
          <Tabs.Panel value="query" pt="lg" mih={640}>
            <QueryTestPanel />
          </Tabs.Panel>
          <Tabs.Panel value="forwarding" pt="lg" mih={640}>
            <ForwardingPanel onSaved={refreshUpstreams} />
          </Tabs.Panel>
          <Tabs.Panel value="audit" pt="lg" mih={640}>
            <AuditLogPanel />
          </Tabs.Panel>
        </Tabs>
      </Stack>
    </Container>
  );
}
