import { useEffect, useState } from "react";
import {
  ActionIcon,
  Badge,
  Button,
  Card,
  Center,
  Group,
  Loader,
  Modal,
  NumberInput,
  Select,
  Stack,
  Switch,
  Table,
  Text,
  TextInput,
  Title,
  Tooltip,
} from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconPencil, IconPlus, IconRefresh, IconTrash } from "@tabler/icons-react";
import { api, errorMessage, type DNSRecord, type RecordType } from "../api";
import { waitForSync } from "../useDnsSync";

/**
 * 저장 성공 토스트를 "DNS 반영 중" 으로 띄운 뒤, 실제 반영이 확인되면
 * 같은 토스트를 "반영 완료 + 소요시간" 으로 바꾼다.
 * 저장 응답(수십 ms)과 DNS 반영(CoreDNS 폴링 주기만큼, 보통 2초 이내)은
 * 서로 다른 시점이므로, 둘을 구분해서 보여준다.
 */
async function notifySaved(title: string, what: string, onChanged?: () => void) {
  const id = `sync-${Date.now()}`;
  onChanged?.();
  notifications.show({
    id,
    loading: true,
    color: "blue",
    title,
    message: `${what} — DNS 반영 중...`,
    autoClose: false,
    withCloseButton: false,
  });
  const ms = await waitForSync();
  notifications.update({
    id,
    loading: false,
    color: ms === null ? "orange" : "teal",
    title: ms === null ? "DNS 반영 확인 실패" : "DNS 반영 완료",
    message:
      ms === null
        ? `${what} — 저장은 됐지만 DNS 반영을 확인하지 못했습니다`
        : `${what} — ${(ms / 1000).toFixed(1)}초 만에 반영됨`,
    autoClose: 3500,
    withCloseButton: true,
  });
}

export default function RecordsPanel({ onChanged }: { onChanged?: () => void }) {
  const [records, setRecords] = useState<DNSRecord[]>([]);
  const [loading, setLoading] = useState(true);

  const [domain, setDomain] = useState("");
  const [recordType, setRecordType] = useState<RecordType>("A");
  const [value, setValue] = useState("");
  const [ttl, setTtl] = useState(30);
  const [submitting, setSubmitting] = useState(false);

  const [togglingId, setTogglingId] = useState<number | null>(null);

  const [editing, setEditing] = useState<DNSRecord | null>(null);
  const [editValue, setEditValue] = useState("");
  const [editTtl, setEditTtl] = useState(30);
  const [savingEdit, setSavingEdit] = useState(false);

  const [deleting, setDeleting] = useState<DNSRecord | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  async function load() {
    setLoading(true);
    try {
      setRecords(await api.listRecords());
    } catch (e) {
      notifications.show({ color: "red", title: "레코드 조회 실패", message: errorMessage(e) });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function handleCreate() {
    setSubmitting(true);
    try {
      await api.createRecord({ domain, record_type: recordType, value, ttl });
      void notifySaved("레코드 등록", domain, onChanged);
      setDomain("");
      setValue("");
      setTtl(30);
      await load();
    } catch (e) {
      notifications.show({ color: "red", title: "등록 실패", message: errorMessage(e) });
    } finally {
      setSubmitting(false);
    }
  }

  async function handleToggle(record: DNSRecord) {
    setTogglingId(record.id);
    try {
      const updated = await api.setRecordEnabled(record.id, !record.enabled);
      void notifySaved(
        updated.enabled ? "레코드 활성화" : "레코드 비활성화",
        `${record.domain} → ${updated.enabled ? "활성" : "비활성"}`,
        onChanged,
      );
      await load();
    } catch (e) {
      notifications.show({ color: "red", title: "상태 변경 실패", message: errorMessage(e) });
    } finally {
      setTogglingId(null);
    }
  }

  async function handleUpdate() {
    if (!editing) return;
    setSavingEdit(true);
    try {
      await api.updateRecord(editing.id, { value: editValue, ttl: editTtl });
      void notifySaved("레코드 수정", editing.domain, onChanged);
      setEditing(null);
      await load();
    } catch (e) {
      notifications.show({ color: "red", title: "수정 실패", message: errorMessage(e) });
    } finally {
      setSavingEdit(false);
    }
  }

  async function handleDelete() {
    if (!deleting) return;
    setConfirmingDelete(true);
    try {
      await api.deleteRecord(deleting.id);
      void notifySaved("레코드 삭제", deleting.domain, onChanged);
      setDeleting(null);
      await load();
    } catch (e) {
      notifications.show({ color: "red", title: "삭제 실패", message: errorMessage(e) });
    } finally {
      setConfirmingDelete(false);
    }
  }

  function openEdit(record: DNSRecord) {
    setEditing(record);
    setEditValue(record.value);
    setEditTtl(record.ttl);
  }

  return (
    <Stack gap="lg">
      <Card withBorder padding="lg" radius="md">
        <Stack gap="md">
          <div>
            <Title order={4}>레코드 등록</Title>
            <Text c="dimmed" size="sm">
              lab.test 존에 A / CNAME 레코드를 추가합니다. 와일드카드는 *.dev.lab.test 형식으로 입력합니다.
            </Text>
          </div>
          <Group align="flex-end" grow>
            <TextInput
              label="도메인"
              placeholder="api.lab.test 또는 *.dev.lab.test"
              value={domain}
              onChange={(e) => setDomain(e.currentTarget.value)}
            />
            <Select
              label="타입"
              data={["A", "CNAME"]}
              value={recordType}
              onChange={(v) => setRecordType((v as RecordType) ?? "A")}
              allowDeselect={false}
            />
            <TextInput
              label={recordType === "A" ? "값 (IPv4)" : "값 (대상 도메인)"}
              placeholder={recordType === "A" ? "172.20.0.2" : "api.lab.test"}
              value={value}
              onChange={(e) => setValue(e.currentTarget.value)}
            />
            <NumberInput
              label="TTL (초)"
              min={1}
              value={ttl}
              onChange={(v) => setTtl(typeof v === "number" ? v : Number(v) || 30)}
            />
          </Group>
          <Group justify="flex-end">
            <Button
              leftSection={<IconPlus size={16} />}
              onClick={handleCreate}
              loading={submitting}
              disabled={!domain.trim() || !value.trim()}
            >
              추가
            </Button>
          </Group>
        </Stack>
      </Card>

      <Card withBorder padding="lg" radius="md">
        <Group justify="space-between" mb="md">
          <Group gap="xs">
            <Title order={4}>등록된 레코드</Title>
            <Badge variant="light" color="gray">
              {records.length}개
            </Badge>
          </Group>
          <Button variant="subtle" leftSection={<IconRefresh size={16} />} onClick={load}>
            새로고침
          </Button>
        </Group>

        {loading ? (
          <Center py="xl">
            <Loader />
          </Center>
        ) : records.length === 0 ? (
          <Center py="xl">
            <Text c="dimmed">등록된 레코드가 없습니다.</Text>
          </Center>
        ) : (
          <Table striped highlightOnHover verticalSpacing="sm">
            <Table.Thead>
              <Table.Tr>
                <Table.Th>도메인</Table.Th>
                <Table.Th>타입</Table.Th>
                <Table.Th>값</Table.Th>
                <Table.Th>TTL</Table.Th>
                <Table.Th>활성화</Table.Th>
                <Table.Th ta="right">작업</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {records.map((record) => (
                <Table.Tr key={record.id} opacity={record.enabled ? 1 : 0.5}>
                  <Table.Td>
                    <Group gap="xs">
                      <Text ff="monospace" size="sm">
                        {record.domain}
                      </Text>
                      {record.domain.startsWith("*") && (
                        <Badge size="xs" color="grape" variant="light">
                          WILDCARD
                        </Badge>
                      )}
                    </Group>
                  </Table.Td>
                  <Table.Td>
                    <Badge variant="light" color={record.record_type === "A" ? "blue" : "cyan"}>
                      {record.record_type}
                    </Badge>
                  </Table.Td>
                  <Table.Td>
                    <Text ff="monospace" size="sm">
                      {record.value}
                    </Text>
                  </Table.Td>
                  <Table.Td>{record.ttl}s</Table.Td>
                  <Table.Td>
                    <Switch
                      checked={record.enabled}
                      onChange={() => handleToggle(record)}
                      disabled={togglingId !== null}
                    />
                  </Table.Td>
                  <Table.Td>
                    <Group gap="xs" justify="flex-end">
                      <Tooltip label="수정">
                        <ActionIcon variant="subtle" onClick={() => openEdit(record)}>
                          <IconPencil size={16} />
                        </ActionIcon>
                      </Tooltip>
                      <Tooltip label="삭제">
                        <ActionIcon variant="subtle" color="red" onClick={() => setDeleting(record)}>
                          <IconTrash size={16} />
                        </ActionIcon>
                      </Tooltip>
                    </Group>
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        )}
      </Card>

      <Modal opened={editing !== null} onClose={() => setEditing(null)} title="레코드 수정" centered>
        <Stack gap="md">
          <TextInput label="도메인" value={editing?.domain ?? ""} disabled />
          <TextInput label="타입" value={editing?.record_type ?? ""} disabled />
          <TextInput label="값" value={editValue} onChange={(e) => setEditValue(e.currentTarget.value)} />
          <NumberInput
            label="TTL (초)"
            min={1}
            value={editTtl}
            onChange={(v) => setEditTtl(typeof v === "number" ? v : Number(v) || 30)}
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={() => setEditing(null)} disabled={savingEdit}>
              취소
            </Button>
            <Button onClick={handleUpdate} loading={savingEdit}>
              저장
            </Button>
          </Group>
        </Stack>
      </Modal>

      <Modal opened={deleting !== null} onClose={() => setDeleting(null)} title="레코드 삭제" centered>
        <Stack gap="md">
          <Text size="sm">
            <Text span ff="monospace" fw={600}>
              {deleting?.domain}
            </Text>{" "}
            ({deleting?.record_type} → {deleting?.value}) 레코드를 삭제할까요?
          </Text>
          <Group justify="flex-end">
            <Button variant="default" onClick={() => setDeleting(null)} disabled={confirmingDelete}>
              취소
            </Button>
            <Button color="red" onClick={handleDelete} loading={confirmingDelete}>
              삭제
            </Button>
          </Group>
        </Stack>
      </Modal>
    </Stack>
  );
}
