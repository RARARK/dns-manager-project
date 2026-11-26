FROM node:20-alpine
WORKDIR /app
# package-lock.json 을 함께 복사하고 npm ci 를 쓴다.
# npm install 은 package.json 의 ^범위를 매번 새로 해석하므로
# 다른 머신/다른 날 빌드하면 의존성 버전이 달라진다.
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# node 이미지에 이미 있는 비root 사용자(node)로 실행한다.
# vite 가 /app 아래에 캐시를 쓰므로 소유권을 넘겨준다.
RUN chown -R node:node /app
USER node
CMD ["npm", "run", "dev"]
