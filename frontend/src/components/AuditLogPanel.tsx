import { useEffect, useState } from "react";
import {
  Badge,
  Button,
  Card,
  Center,
  Group,
  Loader,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconRefresh } from "@tabler/icons-react";
import { api, errorMessage, type AuditLog } from "../api";

const ACTION_COLOR: Record<string, string> = {
  create: "teal",
  update: "blue",
  delete: "red",
  enable: "teal",
  disable: "orange",
};

export default function AuditLogPanel() {
  const [logs, setLogs] = useState<AuditLog[]>([]);
  const [loading, setLoading] = useState(true);

  async function load() {
    setLoading(true);
    try {
      setLogs(await api.listAuditLogs());
    } catch (e) {
      notifications.show({ color: "red", title: "이력 조회 실패", message: errorMessage(e) });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <Card withBorder padding="lg" radius="md">
      <Stack gap="md">
        <Group justify="space-between">
          <div>
            <Title order={4}>변경 이력</Title>
            <Text c="dimmed" size="sm">
              레코드 등록·수정·삭제·활성화 변경 기록입니다.
            </Text>
          </div>
          <Button variant="subtle" leftSection={<IconRefresh size={16} />} onClick={load}>
            새로고침
          </Button>
        </Group>

        {loading ? (
          <Center py="xl">
            <Loader />
          </Center>
        ) : logs.length === 0 ? (
          <Center py="xl">
            <Text c="dimmed">기록된 변경 이력이 없습니다.</Text>
          </Center>
        ) : (
          <Table striped highlightOnHover verticalSpacing="sm">
            <Table.Thead>
              <Table.Tr>
                <Table.Th>시각</Table.Th>
                <Table.Th>액션</Table.Th>
                <Table.Th>도메인</Table.Th>
                <Table.Th>타입</Table.Th>
                <Table.Th>값</Table.Th>
                <Table.Th>상세</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {logs.map((log) => (
                <Table.Tr key={log.id}>
                  <Table.Td>
                    <Text size="sm" c="dimmed">
                      {new Date(log.timestamp + "Z").toLocaleString("ko-KR")}
                    </Text>
                  </Table.Td>
                  <Table.Td>
                    <Badge variant="light" color={ACTION_COLOR[log.action] ?? "gray"}>
                      {log.action}
                    </Badge>
                  </Table.Td>
                  <Table.Td>
                    <Text ff="monospace" size="sm">
                      {log.domain}
                    </Text>
                  </Table.Td>
                  <Table.Td>{log.record_type}</Table.Td>
                  <Table.Td>
                    <Text ff="monospace" size="sm">
                      {log.value}
                    </Text>
                  </Table.Td>
                  <Table.Td>
                    <Text size="sm" c="dimmed">
                      {log.detail ?? "-"}
                    </Text>
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        )}
      </Stack>
    </Card>
  );
}
