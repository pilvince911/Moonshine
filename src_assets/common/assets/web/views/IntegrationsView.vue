<script setup lang="ts">
import { onMounted } from 'vue';
import { useRouter } from 'vue-router';
const router = useRouter();
onMounted(() => { void router.replace('/library'); });
</script>

<template><p>La bibliothèque Moonshine regroupe les intégrations de jeux.</p></template>
