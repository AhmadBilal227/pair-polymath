
import { prisma } from '../lib/db';

export async function listUsersWithPosts(req, res) {
  const users = await prisma.user.findMany({ where: { deletedAt: null } });

  // BUG: this loop fires one DB query per user. For N users that's 1 + N
  // total queries — the classic n+1. Fix is `include: { posts: true }`
  // on the outer findMany, OR a single GROUP BY join.
  const result = [];
  for (const user of users) {
    const posts = await prisma.post.findMany({
      where: { authorId: user.id, deletedAt: null },
      orderBy: { createdAt: 'desc' },
      take: 10,
    });
    result.push({ ...user, posts });
  }

  res.json({ users: result });
}

export async function getUser(req, res) {
  const user = await prisma.user.findUnique({ where: { id: req.params.id } });
  if (!user) return res.status(404).json({ error: 'not found' });
  res.json(user);
}
