import { useState } from "react";
import {
  Badge,
  Button,
  Card,
  Center,
  Group,
  Select,
  Stack,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconSearch } from "@tabler/icons-react";
import { api, errorMessage, type QueryResult } from "../api";

const STATUS_COLOR: Record<string, string> = {
  NOERROR: "teal",
  NXDOMAIN: "red",
  TIMEOUT: "orange",
};

export default function QueryTestPanel() {
  const [domain, setDomain] = useState("api.lab.test");
  const [recordType, setRecordType] = useState("A");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<QueryResult | null>(null);

  async function handleQuery() {
    setLoading(true);
    try {
      setResult(await api.queryTest(domain, recordType));
    } catch (e) {
      notifications.show({ color: "red", title: "질의 실패", message: errorMessage(e) });
    } finally {
      setLoading(false);
    }
  }

  return (
    <Stack gap="lg">
      <Card withBorder padding="lg" radius="md">
        <Stack gap="md">
          <div>
            <Title order={4}>DNS 질의 테스트</Title>
            <Text c="dimmed" size="sm">
              CoreDNS에 직접 질의합니다. 내부 도메인은 로컬 존에서, 외부 도메인은 upstream으로 전달됩니다.
            </Text>
          </div>
          <Group align="flex-end">
            <TextInput
              label="도메인"
              placeholder="api.lab.test / google.com"
              value={domain}
              onChange={(e) => setDomain(e.currentTarget.value)}
              style={{ flex: 1 }}
              onKeyDown={(e) => e.key === "Enter" && handleQuery()}
            />
            <Select
              label="타입"
              data={["A", "AAAA", "CNAME"]}
              value={recordType}
              onChange={(v) => setRecordType(v ?? "A")}
              allowDeselect={false}
              w={120}
            />
            <Button
              leftSection={<IconSearch size={16} />}
              onClick={handleQuery}
              loading={loading}
              disabled={!domain.trim()}
            >
              조회
            </Button>
          </Group>
        </Stack>
      </Card>

      {result && (
        <Card withBorder padding="lg" radius="md">
          <Stack gap="md">
            <Group justify="space-between">
              <Group gap="xs">
                <Text ff="monospace" fw={600}>
                  {result.domain}
                </Text>
                <Badge variant="light">{result.record_type}</Badge>
              </Group>
              <Group gap="xs">
                <Badge color={STATUS_COLOR[result.status] ?? "gray"}>{result.status}</Badge>
                <Text size="sm" c="dimmed">
                  {result.query_time_ms} ms
                </Text>
              </Group>
            </Group>

            {result.answers.length === 0 ? (
              <Center py="md">
                <Text c="dimmed" size="sm">
                  응답 레코드가 없습니다.
                </Text>
              </Center>
            ) : (
              <Table withTableBorder verticalSpacing="xs">
                <Table.Thead>
                  <Table.Tr>
                    <Table.Th>이름</Table.Th>
                    <Table.Th>타입</Table.Th>
                    <Table.Th>TTL</Table.Th>
                    <Table.Th>응답 값</Table.Th>
                  </Table.Tr>
                </Table.Thead>
                <Table.Tbody>
                  {result.answers.map((answer, index) => (
                    <Table.Tr key={`${answer.data}-${index}`}>
                      <Table.Td>
                        <Text ff="monospace" size="sm">
                          {answer.name}
                        </Text>
                      </Table.Td>
                      <Table.Td>{answer.type}</Table.Td>
                      <Table.Td>{answer.ttl}s</Table.Td>
                      <Table.Td>
                        <Text ff="monospace" size="sm" fw={600}>
                          {answer.data}
                        </Text>
                      </Table.Td>
                    </Table.Tr>
                  ))}
                </Table.Tbody>
              </Table>
            )}
          </Stack>
        </Card>
      )}
    </Stack>
  );
}
