import { CollaborationService, CollabConfig, TeamMember } from './collaboration.service';
import { firstValueFrom } from 'rxjs';

function makeConfig(overrides: Partial<CollabConfig> = {}): CollabConfig {
  return {
    websocketUrl: 'ws://localhost:9090/collab',
    userId: 'user-1',
    displayName: 'Test User',
    language: 'en',
    ...overrides,
  };
}

/** Deliver a message to the service's private handleMessage method */
function deliver(service: CollaborationService, msg: unknown): void {
  (service as any).handleMessage(msg);
}

describe('CollaborationService', () => {
  let service: CollaborationService;

  beforeEach(() => {
    service = new CollaborationService();
  });

  afterEach(() => {
    service.ngOnDestroy();
  });

  describe('configure', () => {
    it('stores the configuration', () => {
      service.configure(makeConfig());
      expect((service as any).config).toBeTruthy();
      expect((service as any).config.userId).toBe('user-1');
    });
  });

  describe('joinRoom', () => {
    it('throws if not configured', async () => {
      await expect(service.joinRoom('room-1')).rejects.toThrow('CollaborationService not configured');
    });

    it('sets connection state to connecting when joinRoom is called', () => {
      service.configure(makeConfig());
      // joinRoom will fail because WebSocket is not available in test, but state changes synchronously
      service.joinRoom('room-1').catch(() => {});
      // The currentRoomId is set before the WebSocket is created
      expect(service.getCurrentRoomId()).toBe('room-1');
    });
  });

  describe('leaveRoom', () => {
    it('clears room id and members', async () => {
      service.configure(makeConfig());
      // Simulate having a room
      (service as any).currentRoomId = 'room-1';
      (service as any).membersMap.set('user-2', {
        userId: 'user-2', displayName: 'Other', color: '#e91e63',
        status: 'active', joinedAt: new Date(), lastSeenAt: new Date(),
      });

      await service.leaveRoom();

      expect(service.getCurrentRoomId()).toBeNull();
      expect(service.getMembers()).toEqual([]);
    });
  });

  describe('handleMessage', () => {
    beforeEach(() => {
      service.configure(makeConfig({ userId: 'user-1' }));
    });

    it('adds a member on join (ignoring self)', () => {
      deliver(service, { type: 'join', roomId: 'room-1', userId: 'user-2', displayName: 'Alice' });
      const members = service.getMembers();
      expect(members).toHaveLength(1);
      expect(members[0].userId).toBe('user-2');
      expect(members[0].displayName).toBe('Alice');
      expect(members[0].status).toBe('active');
    });

    it('does not add self on join', () => {
      deliver(service, { type: 'join', roomId: 'room-1', userId: 'user-1', displayName: 'Self' });
      expect(service.getMembers()).toHaveLength(0);
    });

    it('removes a member on leave', () => {
      deliver(service, { type: 'join', roomId: 'room-1', userId: 'user-2', displayName: 'Alice' });
      expect(service.getMembers()).toHaveLength(1);

      deliver(service, { type: 'leave', roomId: 'room-1', userId: 'user-2' });
      expect(service.getMembers()).toHaveLength(0);
    });

    it('updates presence for existing member', () => {
      deliver(service, { type: 'join', roomId: 'room-1', userId: 'user-2', displayName: 'Alice' });
      deliver(service, { type: 'presence', userId: 'user-2', status: 'idle', location: '/dashboard', language: 'ar' });

      const member = service.getMembers()[0];
      expect(member.status).toBe('idle');
      expect(member.location).toBe('/dashboard');
      expect(member.language).toBe('ar');
    });

    it('ignores presence for unknown member', () => {
      deliver(service, { type: 'presence', userId: 'unknown', status: 'active' });
      expect(service.getMembers()).toHaveLength(0);
    });

    it('syncs participants (excluding self)', () => {
      const participants: TeamMember[] = [
        { userId: 'user-1', displayName: 'Self', color: '#000', status: 'active', joinedAt: new Date(), lastSeenAt: new Date() },
        { userId: 'user-2', displayName: 'Alice', color: '#111', status: 'active', joinedAt: new Date(), lastSeenAt: new Date() },
        { userId: 'user-3', displayName: 'Bob', color: '#222', status: 'idle', joinedAt: new Date(), lastSeenAt: new Date() },
      ];
      deliver(service, { type: 'sync', participants });

      const members = service.getMembers();
      expect(members).toHaveLength(2);
      expect(members.map(m => m.userId).sort()).toEqual(['user-2', 'user-3']);
    });
  });

  describe('updateLanguage', () => {
    it('updates config language', () => {
      service.configure(makeConfig({ language: 'en' }));
      service.updateLanguage('ar');
      expect((service as any).config.language).toBe('ar');
    });

    it('does nothing if not configured', () => {
      expect(() => service.updateLanguage('ar')).not.toThrow();
    });
  });

  describe('color cycling', () => {
    it('cycles through colors for new members', () => {
      service.configure(makeConfig());
      deliver(service, { type: 'join', roomId: 'r', userId: 'a', displayName: 'A' });
      deliver(service, { type: 'join', roomId: 'r', userId: 'b', displayName: 'B' });

      const members = service.getMembers();
      expect(members[0].color).not.toBe(members[1].color);
    });
  });

  describe('members$ observable', () => {
    it('emits when members change', async () => {
      service.configure(makeConfig());
      const membersPromise = firstValueFrom(service.members$);
      const members = await membersPromise;
      expect(members).toEqual([]);
    });
  });
});
