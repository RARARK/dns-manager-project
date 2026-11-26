import { useEffect, useState } from "react";
import {
  ActionIcon,
  Alert,
  Button,
  Card,
  Center,
  Code,
  Group,
  Loader,
  Stack,
  Text,
  TextInput,
  Title,
  Tooltip,
} from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconDeviceFloppy, IconInfoCircle, IconPlus, IconTrash } from "@tabler/icons-react";
import { api, errorMessage } from "../api";

const MAX_UPSTREAMS = 5;

export default function ForwardingPanel({ onSaved }: { onSaved?: () => void }) {
  const [saved, setSaved] = useState<string[]>([]);
  const [draft, setDraft] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  async function load() {
    setLoading(true);
    try {
      const config = await api.getForwarding();
      setSaved(config.upstreams);
      setDraft(config.upstreams);
    } catch (e) {
      notifications.show({ color: "red", title: "설정 조회 실패", message: errorMessage(e) });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function handleSave() {
    setSaving(true);
    try {
      const config = await api.setForwarding(draft.map((u) => u.trim()).filter(Boolean));
      setSaved(config.upstreams);
      setDraft(config.upstreams);
      onSaved?.();
      notifications.show({
        color: "teal",
        title: "Forwarding 설정 변경",
        message: `upstream → ${config.upstreams.join(", ")}`,
      });
    } catch (e) {
      notifications.show({ color: "red", title: "설정 변경 실패", message: errorMessage(e) });
    } finally {
      setSaving(false);
    }
  }

  const cleaned = draft.map((u) => u.trim()).filter(Boolean);
  const dirty = JSON.stringify(cleaned) !== JSON.stringify(saved);

  return (
    <Stack gap="lg">
      <Card withBorder padding="lg" radius="md">
        <Stack gap="md">
          <div>
            <Title order={4}>Upstream DNS (외부 도메인 전달)</Title>
            <Text c="dimmed" size="sm">
              lab.test 존에 없는 도메인은 여기에 지정한 서버로 전달됩니다. 위에서부터 순서대로 시도합니다.
            </Text>
          </div>

          {loading ? (
            <Center py="xl">
              <Loader />
            </Center>
          ) : (
            <Stack gap="xs">
              {draft.map((value, index) => (
                <Group key={index} gap="xs" align="flex-end">
                  <TextInput
                    label={index === 0 ? "주소 (IP 또는 IP:포트)" : undefined}
                    placeholder="8.8.8.8"
                    value={value}
                    onChange={(e) => {
                      const next = [...draft];
                      next[index] = e.currentTarget.value;
                      setDraft(next);
                    }}
                    style={{ flex: 1 }}
                    ff="monospace"
                  />
                  <Tooltip label="삭제">
                    <ActionIcon
                      variant="subtle"
                      color="red"
                      size="lg"
                      disabled={draft.length <= 1}
                      onClick={() => setDraft(draft.filter((_, i) => i !== index))}
                    >
                      <IconTrash size={16} />
                    </ActionIcon>
                  </Tooltip>
                </Group>
              ))}

              <Group justify="space-between" mt="xs">
                <Button
                  variant="subtle"
                  leftSection={<IconPlus size={16} />}
                  disabled={draft.length >= MAX_UPSTREAMS}
                  onClick={() => setDraft([...draft, ""])}
                >
                  서버 추가
                </Button>
                <Group gap="xs">
                  <Button variant="default" onClick={() => setDraft(saved)} disabled={!dirty || saving}>
                    되돌리기
                  </Button>
                  <Button
                    leftSection={<IconDeviceFloppy size={16} />}
                    onClick={handleSave}
                    loading={saving}
                    disabled={!dirty || cleaned.length === 0}
                  >
                    저장
                  </Button>
                </Group>
              </Group>
            </Stack>
          )}
        </Stack>
      </Card>

      <Alert variant="light" color="blue" icon={<IconInfoCircle size={18} />} title="적용 방식">
        <Stack gap={4}>
          <Text size="sm">
            저장하면 백엔드가 CoreDNS 설정 파일(<Code>Corefile</Code>)을 다시 생성하고, CoreDNS가 변경을
            감지해 스스로 설정을 다시 읽습니다. 컨테이너 재시작은 필요하지 않습니다.
          </Text>
          <Text size="sm" c="dimmed">
            반영까지 최대 약 6초가 걸립니다. 새 설정이 잘못된 경우 CoreDNS는 직전 설정을 그대로 유지합니다.
          </Text>
          <Text size="sm" mt={4}>
            현재 적용된 값: <Code>{saved.join("  ")}</Code>
          </Text>
        </Stack>
      </Alert>
    </Stack>
  );
}
